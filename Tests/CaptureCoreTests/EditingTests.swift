import Testing
import Foundation
import CoreGraphics
@testable import CaptureCore

private func patternedImage(width: Int = 240, height: Int = 1800) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    var seed: UInt32 = 4371
    for row in 0..<height {
        seed = 1664525 &* seed &+ 1013904223
        let value = Double((seed >> 16) & 255) / 255
        context.setFillColor(CGColor(srgbRed: value, green: value * 0.8, blue: 1 - value, alpha: 1))
        context.fill(CGRect(x: 0, y: row, width: width, height: 1))
    }
    return try #require(context.makeImage())
}

private func rgb(_ image: CGImage, x: Int, y: Int) throws -> [Int] {
    let color = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
    let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(color, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let bytes = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
    return (0..<3).map { Int(bytes[$0]) }
}

@Test func oldPreferencesMigrateWithoutLosingShortcutOrPreset() throws {
    var value = AppPreferences()
    value.shortcut = Shortcut(keyCode: 18, modifiers: (1 << 8) | (1 << 11), keyLabel: "1")
    value.activeStyle.windowFrame = true
    value.customPresets = [StylePreset(name: "我的窗口", style: value.activeStyle)]
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    object.removeValue(forKey: "captureOptions")
    var style = try #require(object["activeStyle"] as? [String: Any]); style.removeValue(forKey: "windowAppearance"); style.removeValue(forKey: "windowTitle"); object["activeStyle"] = style
    var presets = try #require(object["customPresets"] as? [[String: Any]])
    presets[0]["style"] = style; object["customPresets"] = presets
    let restored = try JSONDecoder().decode(AppPreferences.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(restored.isValid)
    #expect(restored.shortcut == value.shortcut)
    #expect(restored.customPresets.first?.name == "我的窗口")
    #expect(restored.activeStyle.windowAppearance == .light)
    #expect(restored.activeStyle.windowTitle == "")
}

@Test func windowChromeChangesAppearanceWithoutChangingScreenshotContent() throws {
    let source = try patternedImage(width: 600, height: 300)
    var style = CaptureStyle(); style.padding = 30; style.windowFrame = true; style.windowTitle = "Notes — 今日计划"
    let light = try StyleCompositor.render(source, style: style)
    style.windowAppearance = .dark
    let dark = try StyleCompositor.render(source, style: style)
    #expect(light.width == dark.width && light.height == dark.height)
    let lightHeader = try rgb(light, x: 520, y: 45).reduce(0, +)
    let darkHeader = try rgb(dark, x: 520, y: 45).reduce(0, +)
    #expect(lightHeader > darkHeader + 300)
    #expect(try rgb(light, x: 200, y: 200) == rgb(dark, x: 200, y: 200))
}

@Test func editCoordinatesRoundTripAcrossCropRotationAndMirror() {
    for rotation in 0..<4 {
        for horizontal in [false, true] {
            for vertical in [false, true] {
                var edits = ImageEdits(); edits.crop = UnitRect(x: 0.1, y: 0.2, width: 0.7, height: 0.6)
                edits.quarterTurns = rotation; edits.flipHorizontal = horizontal; edits.flipVertical = vertical
                let point = UnitPoint(0.37, 0.61)
                let restored = edits.originalPoint(edits.displayPoint(point))
                #expect(abs(restored.x - point.x) < 0.000001)
                #expect(abs(restored.y - point.y) < 0.000001)
            }
        }
    }
}

@Test func solidRedactionIsFlattenedAndOriginalIsPreserved() throws {
    let source = try patternedImage(width: 240, height: 200)
    let before = try StyleCompositor.encode(source)
    var edits = ImageEdits()
    edits.annotations = [Annotation(kind: .redact, start: UnitPoint(0.2, 0.2), end: UnitPoint(0.7, 0.65))]
    let redacted = try EditedImageRenderer.render(source, edits: edits)
    let decoded = try StyleCompositor.decode(StyleCompositor.encode(redacted))
    #expect(try rgb(decoded, x: 100, y: 80).allSatisfy { $0 < 20 })
    #expect(try rgb(decoded, x: 15, y: 15) == rgb(source, x: 15, y: 15))
    #expect(try StyleCompositor.encode(source) == before)
}

@Test func rotatedPixelsMatchCoordinateMappingAndCrop() throws {
    let source = try patternedImage(width: 180, height: 240)
    for turn in 0..<4 {
        var edits = ImageEdits(); edits.crop = UnitRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6)
        edits.quarterTurns = turn; edits.flipHorizontal = true
        let output = try EditedImageRenderer.render(source, edits: edits)
        let dimensions = edits.displayedSize(source: CGSize(width: source.width, height: source.height))
        #expect(output.width == Int(dimensions.width) && output.height == Int(dimensions.height))
        let displayed = UnitPoint(0.37, 0.43), original = edits.originalPoint(displayed)
        let expected = try rgb(source, x: Int(original.x * Double(source.width)), y: Int(original.y * Double(source.height)))
        let actual = try rgb(output, x: Int(displayed.x * Double(output.width)), y: Int(displayed.y * Double(output.height)))
        // Nearest-pixel positions can differ by one source pixel after a 90-degree rotation.
        let candidates = [-1, 0, 1].compactMap { offset -> [Int]? in try? rgb(source, x: Int(original.x * Double(source.width)), y: Int(original.y * Double(source.height)) + offset) }
        #expect(actual == expected || candidates.contains(actual))
    }
}

@Test func scrollingFindsOverlapAndAppendsOnlyNewPixels() throws {
    let source = try patternedImage()
    let first = try #require(source.cropping(to: CGRect(x: 0, y: 0, width: 240, height: 600)))
    let second = try #require(source.cropping(to: CGRect(x: 0, y: 147, width: 240, height: 600)))
    #expect(ImageStitcher.match(previous: first, next: first) == .unchanged)
    #expect(ImageStitcher.match(previous: first, next: second) == .append(147))
    let output = try ImageStitcher.append(first, frame: second, newRows: 147)
    #expect(output.width == 240 && output.height == 747)
    for row in [0, 50, 599, 600, 700, 746] { #expect(try rgb(output, x: 100, y: row) == rgb(source, x: 100, y: row)) }
    #expect(ImageStitcher.match(previous: second, next: first) == .noMatch)
}

@Test func combiningImagesNormalizesWidthsAndPreservesOrder() throws {
    let first = try patternedImage(width: 240, height: 300), second = try patternedImage(width: 120, height: 200)
    let output = try ImageStitcher.combine([first, second])
    #expect(output.width == 240 && output.height == 716)
    #expect(try rgb(output, x: 80, y: 30) == rgb(first, x: 80, y: 30))
    #expect(try rgb(output, x: 80, y: 307).allSatisfy { $0 == 255 })
}

@Test func defaultPresetMustReferenceAnExistingPreset() {
    var preferences = AppPreferences(); preferences.defaultPresetID = "missing"
    #expect(!preferences.isValid)
    preferences.defaultPresetID = StylePreset.builtIns[0].id
    #expect(preferences.isValid)
    let custom = StylePreset(name: "自己的默认", style: CaptureStyle())
    preferences.customPresets = [custom]; preferences.defaultPresetID = custom.id
    #expect(preferences.isValid)
    preferences.customPresets.removeAll()
    #expect(!preferences.isValid)
}

@Test func tinyScreenshotsStillFitTheWindowControls() throws {
    var style = CaptureStyle(); style.windowFrame = true; style.padding = 0
    let layout = try RenderLayout.make(source: CGSize(width: 20, height: 24), style: style)
    #expect(layout.cardRect.width >= 100)
    #expect(CGRect(origin: .zero, size: layout.canvasSize).contains(layout.cardRect))
    #expect(layout.cardRect.contains(layout.imageRect))
}

@Test func textAddedAfterRotationStaysUpright() throws {
    let context = try #require(CGContext(data: nil, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 800,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
    var edits = ImageEdits(); edits.quarterTurns = 1
    var text = Annotation(kind: .text, start: edits.originalPoint(UnitPoint(0.12, 0.12)), end: edits.originalPoint(UnitPoint(0.9, 0.4)), lineWidth: 4, text: "AB")
    text.textQuarterTurns = 1; edits.annotations = [text]
    let output = try EditedImageRenderer.render(#require(context.makeImage()), edits: edits)
    let data = try #require(output.dataProvider?.data), bytes = try #require(CFDataGetBytePtr(data))
    var minX = output.width, minY = output.height, maxX = 0, maxY = 0
    for y in 0..<output.height {
        for x in 0..<output.width {
            let index = y * output.bytesPerRow + x * 4
            if bytes[index] > 200 && bytes[index + 1] < 120 && bytes[index + 2] < 120 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    #expect(maxX - minX > maxY - minY)
    #expect(maxY > minY)
}
