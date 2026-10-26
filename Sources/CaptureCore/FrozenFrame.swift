import CoreGraphics

/// An immutable, native-resolution frame. Selection/preview never recaptures the desktop.
public struct FrozenFrame: @unchecked Sendable {
    public let image: CGImage
    public let pointSize: CGSize
    public var scale: Double { Double(image.width) / pointSize.width }

    public init(image: CGImage, pointSize: CGSize) throws {
        guard pointSize.width.isFinite, pointSize.height.isFinite, pointSize.width > 0, pointSize.height > 0,
              image.width * image.height <= StyleCompositor.maximumPixels,
              abs(Double(image.height) / pointSize.height - Double(image.width) / pointSize.width) < 0.02 else {
            throw CaptureFailure.invalidImage
        }
        self.image = image; self.pointSize = pointSize
    }
    public func cropped(to selection: CGRect) throws -> CGImage {
        guard selection.origin.x.isFinite, selection.origin.y.isFinite, selection.width.isFinite, selection.height.isFinite,
              selection.width > 0, selection.height > 0 else { throw CaptureFailure.invalidImage }
        let rect = SelectionGeometry.pixelRectangle(for: selection, backingScale: scale)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !rect.isNull, !rect.isEmpty, let crop = image.cropping(to: rect),
              let context = CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureFailure.invalidImage }
        context.interpolationQuality = .none; context.setBlendMode(.copy)
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        guard let output = context.makeImage() else { throw CaptureFailure.encoding }
        return output
    }
}

extension SelectionGeometry {
    public static func toolbarFrame(for selection: CGRect, size: CGSize, in bounds: CGRect) -> CGRect {
        let width = min(size.width, max(0, bounds.width - 16)), height = min(size.height, max(0, bounds.height - 16))
        let x = min(max(bounds.minX + 8, selection.maxX - width), bounds.maxX - width - 8)
        let y: Double
        if selection.maxY + height + 16 <= bounds.maxY { y = selection.maxY + 12 }
        else if selection.minY - height - 12 >= bounds.minY { y = selection.minY - height - 12 }
        else { y = bounds.maxY - height - 8 }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
