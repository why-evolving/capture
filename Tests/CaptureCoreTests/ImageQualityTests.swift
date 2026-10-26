import Testing
import Foundation
import CoreGraphics
@testable import CaptureCore

private func sharpPattern(width: Int, height: Int) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    for y in stride(from: 0, to: height, by: 2) { context.fill(CGRect(x: 0, y: y, width: width, height: 1)) }
    for x in stride(from: 0, to: width / 2, by: 2) { context.fill(CGRect(x: x, y: 0, width: 1, height: height)) }
    return try #require(context.makeImage())
}

private func rgbaBytes(_ image: CGImage) throws -> [UInt8] {
    let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Array(UnsafeBufferPointer(start: try #require(context.data?.assumingMemoryBound(to: UInt8.self)), count: image.width * image.height * 4))
}

@Test(arguments: [CGSize(width: 1335, height: 1081), CGSize(width: 1334, height: 1080), CGSize(width: 721, height: 451)])
func windowDecorationPreservesOriginalInteriorPixels(_ size: CGSize) throws {
    let source = try sharpPattern(width: Int(size.width), height: Int(size.height))
    var style = CaptureStyle(); style.padding = 36; style.radius = 22; style.windowFrame = true
    let layout = try RenderLayout.make(source: size, style: style)
    let output = try StyleCompositor.render(source, style: style)
    // Compare the whole interior, excluding the intentionally rounded corners and border.
    let inset = 40
    let expected = try #require(source.cropping(to: CGRect(x: inset, y: inset, width: source.width - inset * 2, height: source.height - inset * 2)))
    let actual = try #require(output.cropping(to: CGRect(x: Int(layout.imageRect.minX.rounded()) + inset,
        y: Int((Double(output.height) - layout.imageRect.maxY).rounded()) + inset,
        width: expected.width, height: expected.height)))
    let a = try rgbaBytes(expected), b = try rgbaBytes(actual)
    let changed = zip(a, b).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
    #expect(changed == 0, "Decoration changed \(changed) interior color channels at 1×")
}

@Test func originalScaleLayoutsPlaceContentOnWholePixels() throws {
    for frame in [false, true] {
        for ratio in CanvasRatio.allCases {
            for position in VerticalPosition.allCases {
                var style = CaptureStyle(); style.windowFrame = frame; style.ratio = ratio; style.position = position
                let layout = try RenderLayout.make(source: CGSize(width: 1335, height: 1081), style: style)
                #expect(layout.imageRect.minX == layout.imageRect.minX.rounded())
                #expect(layout.imageRect.minY == layout.imageRect.minY.rounded())
                #expect(layout.imageRect.size == CGSize(width: 1335, height: 1081))
            }
        }
    }
}

@Test func fractionalSelectionsCoverNativePixelsWithoutScaling() {
    let selection = CGRect(x: 12.25, y: 8.75, width: 100.5, height: 60.25)
    #expect(SelectionGeometry.pixelRectangle(for: selection, backingScale: 2) == CGRect(x: 24, y: 17, width: 202, height: 121))
    #expect(SelectionGeometry.pixelSize(for: selection, backingScale: 2) == CGSize(width: 202, height: 121))
    #expect(SelectionGeometry.pixelRectangle(for: CGRect(x: 25, y: 40, width: 800, height: 500), backingScale: 2) == CGRect(x: 50, y: 80, width: 1600, height: 1000))
}

@Test func pngRoundTripRetainsSharpDecoratedContent() throws {
    let source = try sharpPattern(width: 721, height: 451)
    var style = CaptureStyle(); style.windowFrame = true; style.padding = 36
    let layout = try RenderLayout.make(source: CGSize(width: source.width, height: source.height), style: style)
    let result = try StyleCompositor.decode(StyleCompositor.encode(StyleCompositor.render(source, style: style)))
    let expected = try #require(source.cropping(to: CGRect(x: 40, y: 40, width: 640, height: 370)))
    let actual = try #require(result.cropping(to: CGRect(x: layout.imageRect.minX + 40,
        y: Double(result.height) - layout.imageRect.maxY + 40, width: 640, height: 370)))
    #expect(try rgbaBytes(actual) == rgbaBytes(expected))
}

@Test func constrainedSquaresStaySquareAtEveryEdge() {
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    for start in [CGPoint(x: 100, y: 100), CGPoint(x: 790, y: 590), CGPoint(x: 400, y: 300)] {
        for end in [CGPoint(x: 900, y: 900), CGPoint(x: -100, y: -100), CGPoint(x: 850, y: 2), CGPoint(x: 0, y: 650)] {
            let rect = SelectionGeometry.rectangle(from: start, to: end, in: bounds, square: true)
            #expect(rect.width == rect.height)
            #expect(bounds.contains(rect))
        }
    }
    #expect(SelectionGeometry.rectangle(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 250, y: 100), in: bounds, square: true).size == CGSize(width: 150, height: 150))
}
