import CoreGraphics
import Foundation

public enum ScrollMatch: Equatable, Sendable { case unchanged, append(Int), noMatch }

public enum ImageStitcher {
    /// Match a textured bottom strip against the new frame; ambiguous matches are rejected.
    public static func match(previous: CGImage, next: CGImage) -> ScrollMatch {
        guard previous.width == next.width, previous.height == next.height, previous.height >= 120,
              let old = grayscale(previous), let new = grayscale(next) else { return .noMatch }
        let columns = 64, height = previous.height
        var difference = 0.0, samples = 0
        for index in stride(from: 0, to: old.count, by: 13) { difference += abs(Double(old[index]) - Double(new[index])); samples += 1 }
        if difference / Double(max(1, samples)) < 0.8 { return .unchanged }
        let strip = min(240, max(60, height / 2)), start = height - strip
        let patch = Array(old[(start * columns)..<(height * columns)])
        let mean = patch.reduce(0.0) { $0 + Double($1) } / Double(patch.count)
        let variance = patch.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(patch.count)
        guard variance > 12 else { return .noMatch }
        func score(_ shift: Int) -> Double {
            let newStart = start - shift
            var total = 0.0, weights = 0.0
            for row in stride(from: 0, to: strip, by: 5) {
                for column in stride(from: 2, to: columns - 2, by: 3) {
                    let a = Double(old[(start + row) * columns + column]), b = Double(new[(newStart + row) * columns + column])
                    let weight = 1 + (255 - min(a, b)) / 64
                    total += abs(a - b) * weight; weights += weight
                }
            }
            return total / max(1, weights)
        }
        let candidates = (1...(height - strip)).map { ($0, score($0)) }
        guard let best = candidates.min(by: { $0.1 < $1.1 }), best.1 < 6 else { return .noMatch }
        if candidates.contains(where: { abs($0.0 - best.0) > 28 && $0.1 < 0.4 && best.1 < 0.4 }) { return .noMatch }
        return .append(best.0)
    }
    public static func append(_ accumulated: CGImage, frame: CGImage, newRows: Int) throws -> CGImage {
        let height = accumulated.height + newRows
        guard accumulated.width == frame.width, newRows > 0, newRows <= frame.height,
              height <= 19_500, accumulated.width <= StyleCompositor.maximumPixels / height,
              let bottom = frame.cropping(to: CGRect(x: 0, y: frame.height - newRows, width: frame.width, height: newRows)),
              let context = context(width: accumulated.width, height: height) else { throw CaptureFailure.imageTooLarge }
        context.draw(accumulated, in: CGRect(x: 0, y: newRows, width: accumulated.width, height: accumulated.height))
        context.draw(bottom, in: CGRect(x: 0, y: 0, width: bottom.width, height: newRows))
        guard let image = context.makeImage() else { throw CaptureFailure.encoding }
        return image
    }
    public static func combine(_ images: [CGImage]) throws -> CGImage {
        guard !images.isEmpty, images.count <= 12 else { throw CaptureFailure.invalidImage }
        let width = min(2400, images.map(\.width).max() ?? 1)
        let heights = images.map { max(1, Int(Double($0.height) * Double(width) / Double($0.width))) }
        let gap = 16, height = heights.reduce(0, +) + max(0, images.count - 1) * gap
        guard height <= 19_500, width <= StyleCompositor.maximumPixels / max(1, height), let context = context(width: width, height: height) else { throw CaptureFailure.imageTooLarge }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        var y = height
        for (image, imageHeight) in zip(images, heights) {
            y -= imageHeight; context.draw(image, in: CGRect(x: 0, y: y, width: width, height: imageHeight)); y -= gap
        }
        guard let image = context.makeImage() else { throw CaptureFailure.encoding }
        return image
    }
    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
    private static func grayscale(_ image: CGImage) -> [UInt8]? {
        guard let context = CGContext(data: nil, width: 64, height: image.height, bitsPerComponent: 8, bytesPerRow: 64,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue), let bytes = context.data else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: image.height))
        return Array(UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: UInt8.self), count: 64 * image.height))
    }
}
