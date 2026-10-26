import Testing
import Foundation
import CoreGraphics
@testable import CaptureCore

@Test func selectionMovesPreserveSizeAndStayWithinDisplay() {
    let bounds = CGRect(x: -200, y: -100, width: 800, height: 600)
    let rect = CGRect(x: 20, y: 30, width: 180, height: 120)
    #expect(SelectionGeometry.moved(rect, by: CGSize(width: 17, height: -12), in: bounds) == CGRect(x: 37, y: 18, width: 180, height: 120))
    for delta in [CGSize(width: 1000, height: 1000), CGSize(width: -1000, height: -1000), CGSize(width: 900, height: -900)] {
        let moved = SelectionGeometry.moved(rect, by: delta, in: bounds)
        #expect(moved.size == rect.size)
        #expect(bounds.contains(moved))
    }
}

@Test(arguments: SelectionHandle.allCases)
func selectionResizePreservesOppositeEdgesAndClamps(_ handle: SelectionHandle) {
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    let rect = CGRect(x: 100, y: 100, width: 300, height: 240)
    for delta in [CGSize(width: 40, height: 30), CGSize(width: -1000, height: 1000), CGSize(width: 1000, height: -1000)] {
        let result = SelectionGeometry.resized(rect, handle: handle, by: delta, in: bounds)
        #expect(bounds.contains(result))
        #expect(result.width >= 3 && result.height >= 3)
        if [.topLeft, .left, .bottomLeft].contains(handle) { #expect(result.maxX == rect.maxX) } else { #expect(result.minX == rect.minX) }
        if [.topRight, .right, .bottomRight].contains(handle) { #expect(result.minX == rect.minX) } else { #expect(result.maxX == rect.maxX) }
        if [.topLeft, .top, .topRight].contains(handle) { #expect(result.maxY == rect.maxY) } else { #expect(result.minY == rect.minY) }
        if [.bottomLeft, .bottom, .bottomRight].contains(handle) { #expect(result.minY == rect.minY) } else { #expect(result.maxY == rect.maxY) }
    }
}

@Test func selectionResizingDoesNotStretchUnaffectedAxis() {
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    let rect = CGRect(x: 100, y: 120, width: 300, height: 240)
    #expect(SelectionGeometry.resized(rect, handle: .left, by: CGSize(width: -40, height: 300), in: bounds) == CGRect(x: 60, y: 120, width: 340, height: 240))
    #expect(SelectionGeometry.resized(rect, handle: .bottom, by: CGSize(width: 300, height: 60), in: bounds) == CGRect(x: 100, y: 120, width: 300, height: 300))
    #expect(SelectionGeometry.resized(rect, handle: .topLeft, by: CGSize(width: 1000, height: 1000), in: bounds) == CGRect(x: 397, y: 357, width: 3, height: 3))
}

@Test func adjustableSelectionMigratesAndPersistsWithoutReplacingOtherOptions() throws {
    let legacy = Data(#"{"delay":5,"includeCursor":true}"#.utf8)
    var options = try JSONDecoder().decode(CaptureOptions.self, from: legacy)
    #expect(!(options.adjustBeforeCapture ?? false))
    options.adjustBeforeCapture = true
    let restored = try JSONDecoder().decode(CaptureOptions.self, from: JSONEncoder().encode(options))
    #expect(restored.adjustBeforeCapture == true)
    #expect(restored.delay == 5 && restored.includeCursor)
}

@Test func frozenFrameKeepsNativePixelsAndOwnsCompactCrop() throws {
    let context = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 480,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 60, height: 80))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 60, y: 0, width: 60, height: 80))
    let image = context.makeImage()!
    let frame = try FrozenFrame(image: image, pointSize: CGSize(width: 60, height: 40))
    let selected = CGRect(x: 20.25, y: 5.25, width: 20, height: 10)
    let result = try frame.cropped(to: selected)
    let expected = image.cropping(to: CGRect(x: 40, y: 10, width: 41, height: 21))!
    #expect(result.width == 41 && result.height == 21 && result.bytesPerRow == 41 * 4)
    #expect(try StyleCompositor.encode(result) == StyleCompositor.encode(expected))
    // Changing the live surface cannot change the already acquired frame.
    context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
    #expect(try StyleCompositor.encode(frame.cropped(to: selected)) == StyleCompositor.encode(result))
}

@Test func frozenFrameClampsDisplayEdgesAndRejectsBadCoordinates() throws {
    let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 800,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let frame = try FrozenFrame(image: context.makeImage()!, pointSize: CGSize(width: 100, height: 50))
    let edge = try frame.cropped(to: CGRect(x: 90, y: 45, width: 20, height: 20))
    #expect(edge.width == 20 && edge.height == 10)
    #expect(throws: (any Error).self) { try frame.cropped(to: CGRect(x: 110, y: 0, width: 20, height: 20)) }
    #expect(throws: (any Error).self) { try frame.cropped(to: CGRect(x: Double.nan, y: 0, width: 20, height: 20)) }
    #expect(throws: (any Error).self) { try FrozenFrame(image: frame.image, pointSize: CGSize(width: 0, height: 50)) }
}

@Test func selectionToolbarRemainsReachableAtEveryEdge() {
    for bounds in [CGRect(x: 0, y: 0, width: 940, height: 660), CGRect(x: -500, y: -100, width: 640, height: 360)] {
        for rect in [bounds, CGRect(x: bounds.minX, y: bounds.minY, width: 20, height: 20),
                     CGRect(x: bounds.maxX - 30, y: bounds.maxY - 30, width: 30, height: 30)] {
            #expect(bounds.contains(SelectionGeometry.toolbarFrame(for: rect, size: CGSize(width: 440, height: 78), in: bounds)))
        }
    }
}

@Test func adjustedWorkflowIsDefaultButExplicitQuickModeSurvives() throws {
    #expect(CaptureOptions().allowsSelectionAdjustment)
    var legacy = try JSONDecoder().decode(CaptureOptions.self, from: Data(#"{"delay":3,"includeCursor":true}"#.utf8))
    #expect(legacy.allowsSelectionAdjustment)
    legacy.adjustBeforeCapture = false
    let saved = try JSONDecoder().decode(CaptureOptions.self, from: JSONEncoder().encode(legacy))
    #expect(!saved.allowsSelectionAdjustment && saved.delay == 3 && saved.includeCursor)
}
