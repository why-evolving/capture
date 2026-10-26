import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import CaptureCore

private func sourceImage(width: Int = 120, height: Int = 80) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(srgbRed: 0.1, green: 0.2, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
    return try #require(context.makeImage())
}

@Test func presetsHaveDistinctValidStyles() {
    #expect(StylePreset.builtIns.count == 12)
    #expect(Set(StylePreset.builtIns.map(\.id)).count == 12)
    #expect(StylePreset.builtIns.allSatisfy { $0.style.isValid })
    #expect(StylePreset.builtIns.first?.name == "暮光")
}

@Test func outputGeometryPreservesOriginalAndAddsPadding() throws {
    let layout = try RenderLayout.make(source: CGSize(width: 1440, height: 900), style: CaptureStyle())
    #expect(layout.canvasSize == CGSize(width: 1632, height: 1092))
    #expect(layout.imageRect == CGRect(x: 96, y: 96, width: 1440, height: 900))
}

@Test(arguments: CanvasRatio.allCases)
func fixedRatiosNeverCropImage(_ ratio: CanvasRatio) throws {
    var style = CaptureStyle(); style.ratio = ratio
    let layout = try RenderLayout.make(source: CGSize(width: 500, height: 900), style: style)
    #expect(CGRect(origin: .zero, size: layout.canvasSize).contains(layout.cardRect))
    if let expected = ratio.value { #expect(abs(layout.canvasSize.width / layout.canvasSize.height - expected) < 0.002) }
}

@Test func alignmentAndWindowHeaderStayInsideCanvas() throws {
    var style = CaptureStyle(); style.ratio = .square; style.windowFrame = true; style.imageScale = 70
    style.position = .top
    let top = try RenderLayout.make(source: CGSize(width: 800, height: 400), style: style)
    style.position = .bottom
    let bottom = try RenderLayout.make(source: CGSize(width: 800, height: 400), style: style)
    #expect(abs(top.cardRect.maxY - (top.canvasSize.height - style.padding)) < 0.001)
    #expect(abs(bottom.cardRect.minY - style.padding) < 0.001)
    #expect(top.headerHeight > 0)
    #expect(abs(top.cardRect.height - (top.imageRect.height + top.headerHeight)) < 0.001)
}

@Test func plainCaptureDoesNotApplyAnyStyle() throws {
    let source = try sourceImage()
    let result = try StyleCompositor.render(source, style: nil)
    #expect(result === source)
    #expect(result.width == 120)
    #expect(result.height == 80)
}

@Test func transparentCanvasHasTransparentCorners() throws {
    var style = CaptureStyle()
    style.background = .transparent; style.shadow = 0; style.padding = 20; style.radius = 10
    let output = try StyleCompositor.render(sourceImage(), style: style)
    let data = try #require(output.dataProvider?.data)
    let bytes = try #require(CFDataGetBytePtr(data))
    #expect(bytes[3] == 0)
    let center = 50 * output.bytesPerRow + 50 * 4
    #expect(bytes[center + 3] == 255)
}

@Test(arguments: StylePreset.builtIns)
func everyPresetRendersAndEncodes(_ preset: StylePreset) throws {
    let image = try StyleCompositor.render(sourceImage(), style: preset.style)
    let data = try StyleCompositor.encode(image)
    #expect(Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
    let decoded = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let decodedImage = try #require(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
    #expect(decodedImage.width == image.width)
    #expect(decodedImage.height == image.height)
}

@Test func previewLimitAndJPEGOutput() throws {
    let image = try StyleCompositor.render(sourceImage(), style: CaptureStyle(), previewLimit: 180, opaque: true)
    #expect(max(image.width, image.height) <= 180)
    let jpeg = try StyleCompositor.encode(image, format: .jpeg)
    #expect(Array(jpeg.prefix(2)) == [255, 216])
}

@Test func oversizedExportsFailBeforeAllocatingOutput() throws {
    let source = try sourceImage(width: 2800, height: 2000)
    #expect(throws: CaptureFailure.self) { try StyleCompositor.render(source, style: CaptureStyle(), scale: 3) }
    #expect(throws: CaptureFailure.self) { try StyleCompositor.render(source, style: nil, scale: .infinity) }
}

@Test func invalidNumericStylesAreRejected() throws {
    var style = CaptureStyle(); style.padding = -10
    #expect(!style.isValid)
    #expect(throws: CaptureFailure.self) { try RenderLayout.make(source: CGSize(width: 120, height: 80), style: style) }
    style = CaptureStyle(); style.angle = .nan
    #expect(!style.isValid)
}

@Test func reverseAndRetinaSelectionMapping() {
    let selection = SelectionGeometry.rectangle(from: CGPoint(x: 300, y: 150), to: CGPoint(x: -20, y: 20),
                                                in: CGRect(x: 0, y: 0, width: 500, height: 400))
    #expect(selection == CGRect(x: 0, y: 20, width: 300, height: 130))
    #expect(SelectionGeometry.pixelSize(for: selection, backingScale: 2) == CGSize(width: 600, height: 260))
}

@Test func settingsRetainStyleWhenAutomaticModeIsDisabled() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("preferences.json")
    var value = AppPreferences()
    value.activeStyle = StylePreset.builtIns[1].style
    value.customPresets = [StylePreset(name: "自己的样式", style: value.activeStyle)]
    value.automaticStyle = false
    try PreferencesIO.save(value, to: path)
    let restored = try PreferencesIO.load(from: path)
    #expect(restored == value)
    #expect(restored.customPresets.count == 1)
    #expect(!restored.automaticStyle)
    #expect(restored.activeStyle == StylePreset.builtIns[1].style)
}

@Test func corruptSettingsAreNotSilentlyOverwritten() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("preferences.json")
    let corrupt = Data("{invalid".utf8)
    try corrupt.write(to: url)
    #expect(throws: (any Error).self) { try PreferencesIO.load(from: url) }
    #expect(try Data(contentsOf: url) == corrupt)
}

@Test func shortcutValidationAndDisplay() {
    #expect(Shortcut.defaultCapture.display == "⇧⌘2")
    #expect(Shortcut.defaultCapture.isValid)
    #expect(!Shortcut(keyCode: 19, modifiers: 0, keyLabel: "2").isValid)
    #expect(!Shortcut(keyCode: 19, modifiers: 1 << 9, keyLabel: "2").isValid)
    #expect(!Shortcut(keyCode: 999, modifiers: 1 << 8, keyLabel: "X").isValid)
}
