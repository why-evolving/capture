import Foundation
import CoreGraphics
import ImageIO

public enum CollageDirection: String, Codable, CaseIterable, Sendable {
    case vertical, horizontal, grid
    public var label: String { switch self { case .vertical: return "纵向"; case .horizontal: return "横向"; case .grid: return "双列网格" } }
}
public struct CollageOptions: Equatable, Sendable {
    public var direction: CollageDirection = .vertical
    public var gap = 16
    public var background = RGBColor(hex: "F4F2F8")
    public init() {}
}
public struct CollageLayout: Sendable {
    public let size: CGSize
    /// Top-left origin, in source pixels. Images are never enlarged or resampled.
    public let frames: [CGRect]
    public static func make(sizes: [CGSize], options: CollageOptions) throws -> Self {
        guard (2...12).contains(sizes.count), (0...80).contains(options.gap), options.background.isValid,
              sizes.allSatisfy({ $0.width.isFinite && $0.height.isFinite && $0.width >= 1 && $0.height >= 1 && $0.width <= 19500 && $0.height <= 19500 }) else { throw CaptureFailure.invalidImage }
        let gap = Double(options.gap), maxW = sizes.map(\.width).max()!, maxH = sizes.map(\.height).max()!
        var frames: [CGRect] = [], size = CGSize.zero
        switch options.direction {
        case .vertical:
            var y = 0.0
            for s in sizes { frames.append(CGRect(x: ((maxW-s.width)/2).rounded(.down), y: y, width: s.width, height: s.height)); y += s.height + gap }
            size = CGSize(width: maxW, height: y-gap)
        case .horizontal:
            var x = 0.0
            for s in sizes { frames.append(CGRect(x: x, y: ((maxH-s.height)/2).rounded(.down), width: s.width, height: s.height)); x += s.width + gap }
            size = CGSize(width: x-gap, height: maxH)
        case .grid:
            var y = 0.0
            for row in stride(from: 0, to: sizes.count, by: 2) {
                let height = sizes[row..<min(sizes.count,row+2)].map(\.height).max()!
                for index in row..<min(sizes.count,row+2) {
                    let s = sizes[index]
                    frames.append(CGRect(x: Double(index % 2) * (maxW+gap) + ((maxW-s.width)/2).rounded(.down), y: y + ((height-s.height)/2).rounded(.down), width: s.width, height: s.height))
                }
                y += height + gap
            }
            size = CGSize(width: maxW*2+gap, height: y-gap)
        }
        guard size.width <= 19500, size.height <= 19500, size.width * size.height <= Double(StyleCompositor.maximumPixels) else { throw CaptureFailure.imageTooLarge }
        return Self(size: size, frames: frames)
    }
    public static func loadImages(_ urls: [URL]) throws -> [CGImage] {
        guard (2...12).contains(urls.count) else { throw CaptureFailure.invalidImage }
        var total = 0
        for url in urls {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 19500, height <= 19500,
                  width <= (StyleCompositor.maximumPixels - total) / height else { throw CaptureFailure.imageTooLarge }
            total += width * height
        }
        return try urls.map { try Task.checkCancellation(); return try StyleCompositor.decode($0) }
    }
    public static func render(_ images: [CGImage], options: CollageOptions, previewLimit: Double? = nil) throws -> CGImage {
        let layout = try make(sizes: images.map { CGSize(width: $0.width, height: $0.height) }, options: options)
        let factor = previewLimit.map { min(1, $0 / max(layout.size.width, layout.size.height)) } ?? 1
        guard factor.isFinite, factor > 0 else { throw CaptureFailure.invalidImage }
        let w = max(1, Int((layout.size.width*factor).rounded())), h = max(1, Int((layout.size.height*factor).rounded()))
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureFailure.encoding }
        c.scaleBy(x: factor, y: factor); c.setFillColor(options.background.cgColor); c.fill(CGRect(origin: .zero, size: layout.size)); c.interpolationQuality = factor == 1 ? .none : .high
        for (image, frame) in zip(images, layout.frames) {
            try Task.checkCancellation()
            c.draw(image, in: CGRect(x: frame.minX, y: layout.size.height-frame.maxY, width: frame.width, height: frame.height))
        }
        guard let image = c.makeImage() else { throw CaptureFailure.encoding }; return image
    }
}
