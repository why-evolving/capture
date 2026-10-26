import AppKit
import SwiftUI
import ScreenCaptureKit
import CaptureCore

@MainActor enum FrozenCaptureChecks {
    /// Reads only the generated backdrop, sample and transient panel, never third-party windows.
    static func run(directory: URL) async throws -> [String] {
        guard CGPreflightScreenCaptureAccess(), let screen = NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw DeveloperChecks.CheckBlocked("冻结检查需要解锁桌面与屏幕录制权限。")
        }
        let backdrop = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.isOpaque = true; backdrop.backgroundColor = .black; backdrop.isReleasedWhenClosed = false
        let sample = NSWindow(contentRect: CGRect(x: screen.frame.midX - 360, y: screen.frame.midY - 220, width: 720, height: 440), styleMask: [.borderless], backing: .buffered, defer: false)
        sample.isReleasedWhenClosed = false
        sample.backgroundColor = CaptureTheme.accentNS
        let popup = NSPanel(contentRect: CGRect(x: sample.frame.midX - 150, y: sample.frame.midY - 50, width: 300, height: 120), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        popup.isReleasedWhenClosed = false; popup.backgroundColor = .orange; popup.level = .floating
        popup.contentView = NSHostingView(rootView: VStack(spacing: 8) {
            Text("悬浮提示 · 触发时保留").font(.headline)
            Text("移动鼠标以后消失，也能完整截图").font(.caption)
        }.frame(width: 300, height: 120).background(Color.orange).foregroundStyle(.black))
        backdrop.orderBack(nil); sample.orderFrontRegardless(); popup.orderFrontRegardless()
        defer { for window in [popup, sample, backdrop] { window.orderOut(nil); window.close() } }
        try await Task.sleep(for: .milliseconds(200))
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { throw CaptureFailure.displayUnavailable }
        func item(_ window: NSWindow) throws -> SCWindow {
            guard let match = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw CaptureFailure.displayUnavailable }; return match
        }
        let backgroundItem = try item(backdrop), sampleItem = try item(sample), popupItem = try item(popup)
        let filter = SCContentFilter(display: display, including: [backgroundItem, sampleItem, popupItem])
        let frozen = try await ScreenCaptureService.freeze(filter: filter, size: display.frame.size, scale: screen.backingScaleFactor)
        let region = CGRect(x: popupItem.frame.minX - display.frame.minX, y: popupItem.frame.minY - display.frame.minY, width: popupItem.frame.width, height: popupItem.frame.height)
        let original = try frozen.cropped(to: region)
        let before = try StyleCompositor.encode(original)
        popup.orderOut(nil); sample.backgroundColor = .systemGreen
        try await Task.sleep(for: .milliseconds(150))
        let after = try frozen.cropped(to: region)
        guard !popup.isVisible, try StyleCompositor.encode(after) == before else { throw DeveloperChecks.CheckFailure("悬浮窗消失后冻结图发生变化") }
        let live = try await ScreenCaptureService.freeze(filter: SCContentFilter(display: display, including: [backgroundItem, sampleItem]), size: display.frame.size, scale: screen.backingScaleFactor)
        guard try StyleCompositor.encode(live.cropped(to: region)) != before else { throw DeveloperChecks.CheckFailure("测试没有产生可区分的实时变化") }
        guard original.bytesPerRow == original.width * 4,
              original.width == Int(SelectionGeometry.pixelSize(for: region, backingScale: frozen.scale).width) else {
            throw DeveloperChecks.CheckFailure("冻结图裁剪丢失原生像素或保留全屏内存")
        }
        try before.write(to: directory.appendingPathComponent("frozen-popup-retained.png"))
        try StyleCompositor.encode(live.cropped(to: region)).write(to: directory.appendingPathComponent("live-popup-gone.png"))
        let report: [String: Any] = ["result": "passed", "scope": "include-only generated app windows; transient panel hidden after acquisition", "frozenPixels": [frozen.image.width, frozen.image.height], "cropPixels": [original.width, original.height], "scale": frozen.scale, "frameUnchanged": true, "liveContentChanged": true, "generalClipboardModified": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("frozen-checks.json"))
        return ["frozen-transient-panel-retained", "frozen-live-change-independent", "frozen-native-compact-crop"]
    }
}
