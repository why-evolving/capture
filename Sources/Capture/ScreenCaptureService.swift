import AppKit
import CaptureCore
import ScreenCaptureKit
import CoreVideo

struct CaptureWindow {
    let id: CGWindowID
    let title: String
    let frame: CGRect
}

enum ScreenCaptureService {
    struct FrozenDesktop {
        let frames: [CGDirectDisplayID: FrozenFrame]
        let windows: [CaptureWindow]
    }
    /// Finish all frame acquisition before creating any selection panel or changing focus.
    static func freeze(displays: [(id: CGDirectDisplayID, scale: Double)], includeCursor: Bool) async throws -> FrozenDesktop {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureFailure.permission }
        guard !displays.isEmpty else { throw CaptureFailure.displayUnavailable }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let windows = orderedWindows(content)
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var frames: [CGDirectDisplayID: FrozenFrame] = [:]
        var totalPixels = 0
        for requested in displays {
            try Task.checkCancellation()
            guard let display = content.displays.first(where: { $0.displayID == requested.id }) else { throw CaptureFailure.displayUnavailable }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let configuration = try nativeConfiguration(filter: filter, fallbackSize: display.frame.size, fallbackScale: requested.scale, includeCursor: includeCursor)
            totalPixels += configuration.width * configuration.height
            guard totalPixels <= StyleCompositor.maximumPixels * 2 else { throw CaptureFailure.imageTooLarge }
            frames[requested.id] = try await freeze(filter: filter, size: display.frame.size, scale: requested.scale, includeCursor: includeCursor)
        }
        try Task.checkCancellation()
        return FrozenDesktop(frames: frames, windows: windows)
    }
    // Also used with an include-only filter by the app-owned live regression fixture.
    static func freeze(filter: SCContentFilter, size: CGSize, scale: Double, includeCursor: Bool = false) async throws -> FrozenFrame {
        let configuration = try nativeConfiguration(filter: filter, fallbackSize: size, fallbackScale: scale, includeCursor: includeCursor)
        configuration.ignoreGlobalClipSingleWindow = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        return try FrozenFrame(image: image, pointSize: size)
    }
    static func windows() async throws -> [CaptureWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return orderedWindows(content)
    }
    private static func orderedWindows(_ content: SCShareableContent) -> [CaptureWindow] {
        let ordered = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let order = Dictionary(uniqueKeysWithValues: ordered.enumerated().compactMap { index, info -> (UInt32, Int)? in
            guard let id = info[kCGWindowNumber as String] as? NSNumber else { return nil }; return (id.uint32Value, index)
        })
        // Include transient panels/popovers in frozen window hit testing as well as regular windows.
        return content.windows.filter { $0.windowLayer >= 0 && $0.windowLayer < 25 && $0.frame.width > 30 && $0.frame.height > 25 && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier }
            .sorted { (order[$0.windowID] ?? Int.max) < (order[$1.windowID] ?? Int.max) }
            .map { CaptureWindow(id: $0.windowID, title: $0.title?.isEmpty == false ? $0.title! : ($0.owningApplication?.applicationName ?? "窗口"), frame: $0.frame) }
    }
    static func capture(displayID: CGDirectDisplayID, selection: CGRect, backingScale: Double, includeCursor: Bool = false) async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureFailure.permission }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CaptureFailure.displayUnavailable }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        return try await captureRegion(filter: filter, selection: selection, fallbackScale: backingScale, includeCursor: includeCursor)
    }
    static func captureWindow(id: CGWindowID, size: CGSize, scale: Double, includeCursor: Bool = false) async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureFailure.permission }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureFailure.displayUnavailable }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = try nativeConfiguration(filter: filter, fallbackSize: size, fallbackScale: scale, includeCursor: includeCursor)
        configuration.ignoreShadowsSingleWindow = true; configuration.shouldBeOpaque = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
    /// A user-triggered diagnostic captures this app's sample window only.
    static func captureSample(windowID: CGWindowID, size: CGSize, scale: Double) async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureFailure.permission }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw CaptureFailure.displayUnavailable }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = try nativeConfiguration(filter: filter, fallbackSize: size, fallbackScale: scale, includeCursor: false)
        configuration.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    static func nativeConfiguration(filter: SCContentFilter, fallbackSize: CGSize, fallbackScale: Double, includeCursor: Bool) throws -> SCStreamConfiguration {
        let content = filter.contentRect.size
        let size = content.width > 0 && content.height > 0 ? content : fallbackSize
        let scale = nativeScale(filter: filter, fallback: fallbackScale)
        let pixels = SelectionGeometry.pixelSize(for: CGRect(origin: .zero, size: size), backingScale: scale)
        guard pixels.width.isFinite, pixels.height.isFinite, pixels.width > 0, pixels.height > 0,
              pixels.width <= 20_000, pixels.height <= 20_000,
              pixels.width * pixels.height <= Double(StyleCompositor.maximumPixels) else { throw CaptureFailure.imageTooLarge }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(pixels.width); configuration.height = Int(pixels.height)
        configuration.captureResolution = .best
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = includeCursor; configuration.capturesAudio = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        return configuration
    }

    static func captureRegion(filter: SCContentFilter, selection: CGRect, fallbackScale: Double, includeCursor: Bool = false) async throws -> CGImage {
        let configuration = try nativeConfiguration(filter: filter, fallbackSize: filter.contentRect.size, fallbackScale: fallbackScale, includeCursor: includeCursor)
        configuration.ignoreGlobalClipSingleWindow = false
        // Capture at the content's native pixel grid, then crop whole pixels.
        // sourceRect-based scaling can introduce another interpolation pass.
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        let rect = SelectionGeometry.pixelRectangle(for: selection, backingScale: nativeScale(filter: filter, fallback: fallbackScale))
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !rect.isNull, rect.width > 0, rect.height > 0, let cropped = image.cropping(to: rect) else { throw CaptureFailure.invalidImage }
        // A CGImage crop shares the full display's backing storage and row stride.
        // Keep only the selected pixels in session history and scrolling frames.
        guard let context = CGContext(data: nil, width: cropped.width, height: cropped.height, bitsPerComponent: 8, bytesPerRow: cropped.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureFailure.imageTooLarge }
        context.interpolationQuality = .none; context.setBlendMode(.copy)
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        guard let result = context.makeImage() else { throw CaptureFailure.encoding }
        return result
    }

    private static func nativeScale(filter: SCContentFilter, fallback: Double) -> Double {
        let scale = Double(filter.pointPixelScale)
        return scale.isFinite && scale > 0 ? scale : (fallback.isFinite && fallback > 0 ? fallback : 1)
    }
}
