import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreText

public enum StyleCompositor {
    public static let maximumPixels = 48_000_000

    public static func render(_ source: CGImage, style: CaptureStyle?, scale: Double = 1, previewLimit: Double? = nil, opaque: Bool = false) throws -> CGImage {
        try Task.checkCancellation()
        guard scale.isFinite, scale > 0, scale <= 3 else { throw CaptureFailure.imageTooLarge }
        let sourceSize = CGSize(width: source.width, height: source.height)
        let layout = try style.map { try RenderLayout.make(source: sourceSize, style: $0) }
        let canvas = layout?.canvasSize ?? sourceSize
        var factor = scale
        if let previewLimit { factor = min(factor, previewLimit / max(canvas.width, canvas.height)) }
        let width = max(1, Int((canvas.width * factor).rounded()))
        let height = max(1, Int((canvas.height * factor).rounded()))
        guard width <= 20_000, height <= 20_000, width <= maximumPixels / height else { throw CaptureFailure.imageTooLarge }
        if style == nil, scale == 1, previewLimit == nil, !opaque { return source }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureFailure.imageTooLarge }
        context.scaleBy(x: factor, y: factor)
        context.interpolationQuality = .high
        let canvasRect = CGRect(origin: .zero, size: canvas)
        if opaque { context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(canvasRect) }
        guard let style, let layout else {
            context.draw(source, in: CGRect(origin: .zero, size: sourceSize))
            guard let image = context.makeImage() else { throw CaptureFailure.encoding }
            return image
        }
        switch style.background {
        case .transparent: break
        case .solid: context.setFillColor(style.firstColor.cgColor); context.fill(canvasRect)
        case .gradient, .aurora:
            let colors = [style.firstColor.cgColor, style.secondColor.cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) else { throw CaptureFailure.encoding }
            let radians = (90 - style.angle) * .pi / 180
            let direction = CGPoint(x: cos(radians), y: sin(radians))
            let length = abs(direction.x) * canvas.width / 2 + abs(direction.y) * canvas.height / 2
            let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            context.drawLinearGradient(gradient,
                start: CGPoint(x: center.x - direction.x * length, y: center.y - direction.y * length),
                end: CGPoint(x: center.x + direction.x * length, y: center.y + direction.y * length),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        if style.background == .aurora {
            let colors = [style.secondColor.cgColor.copy(alpha: 0.8)!, style.firstColor.cgColor.copy(alpha: 0)!] as CFArray
            if let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0,1]) {
                let canvas = layout.canvasSize
                context.drawRadialGradient(glow, startCenter: CGPoint(x: canvas.width * 0.15, y: canvas.height * 0.8), startRadius: 0, endCenter: CGPoint(x: canvas.width * 0.15, y: canvas.height * 0.8), endRadius: max(canvas.width, canvas.height) * 0.8, options: [])
                context.drawRadialGradient(glow, startCenter: CGPoint(x: canvas.width * 0.95, y: canvas.height * 0.2), startRadius: 0, endCenter: CGPoint(x: canvas.width * 0.95, y: canvas.height * 0.2), endRadius: max(canvas.width, canvas.height) * 0.6, options: [])
            }
        }
        if style.grain, style.background != .transparent, let noise = grainImage() {
            context.saveGState(); context.setAlpha(0.055)
            context.draw(noise, in: CGRect(x: 0, y: 0, width: 64, height: 64), byTiling: true)
            context.restoreGState()
        }
        let radius = min(style.windowFrame ? max(style.radius, layout.headerHeight * 0.22) : style.radius, min(layout.cardRect.width, layout.cardRect.height) / 2)
        let path = CGPath(roundedRect: layout.cardRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.saveGState()
        if style.shadow > 0 {
            context.setShadow(offset: CGSize(width: 0, height: -style.shadow * 0.32),
                              blur: max(1, style.softness * 0.8),
                              color: CGColor(srgbRed: 0.09, green: 0.055, blue: 0.14, alpha: style.shadow / 160))
        }
        context.addPath(path); context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fillPath()
        context.restoreGState()
        // A tight contact shadow anchors the window beneath the soft ambient shadow.
        if style.windowFrame && style.shadow > 0 {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -2), blur: 4, color: CGColor(gray: 0, alpha: style.shadow / 450))
            context.addPath(path); context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fillPath()
            context.restoreGState()
        }
        context.saveGState()
        context.addPath(path); context.clip()
        if factor == 1 && layout.imageRect.size == sourceSize { context.interpolationQuality = .none }
        context.draw(source, in: layout.imageRect)
        if style.windowFrame {
            let header = CGRect(x: layout.cardRect.minX, y: layout.imageRect.maxY, width: layout.cardRect.width, height: layout.headerHeight)
            drawWindowHeader(context, rect: header, style: style)
        }
        context.restoreGState()
        if style.border || style.windowFrame {
            let inset = layout.cardRect.insetBy(dx: 0.5, dy: 0.5)
            context.addPath(CGPath(roundedRect: inset, cornerWidth: max(0, radius - 0.5), cornerHeight: max(0, radius - 0.5), transform: nil))
            context.setStrokeColor(CGColor(gray: style.windowAppearance == .dark ? 1 : 0, alpha: style.windowFrame ? 0.20 : 0.12))
            context.setLineWidth(1); context.strokePath()
        }
        guard let result = context.makeImage() else { throw CaptureFailure.encoding }
        return result
    }

    public static func encode(_ image: CGImage, format: ImageFormat = .png, quality: Double = 0.92) throws -> Data {
        let data = NSMutableData()
        let type = format == .png ? UTType.png.identifier : UTType.jpeg.identifier
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { throw CaptureFailure.encoding }
        let properties: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: min(1, max(0.1, quality))] : [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CaptureFailure.encoding }
        return data as Data
    }
    private static func drawWindowHeader(_ context: CGContext, rect: CGRect, style: CaptureStyle) {
        let dark = style.windowAppearance == .dark
        let scale = rect.height / 44
        let colors = (dark ? ["3F3E40", "303032"] : ["FAFAFA", "E8E8E9"]).map { RGBColor(hex: $0).cgColor }
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        }
        context.setFillColor(CGColor(gray: dark ? 1 : 0, alpha: dark ? 0.16 : 0.12))
        context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(1, scale * 0.6)))
        context.setFillColor(CGColor(gray: 1, alpha: dark ? 0.16 : 0.9))
        context.fill(CGRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1))
        let diameter = 12 * scale
        for (index, color) in ["FF5F57", "FEBC2E", "28C840"].enumerated() {
            let circle = CGRect(x: rect.minX + (16 + Double(index) * 20) * scale, y: rect.midY - diameter / 2, width: diameter, height: diameter)
            context.setFillColor(RGBColor(hex: color).cgColor); context.fillEllipse(in: circle)
            context.setStrokeColor(CGColor(gray: 0, alpha: dark ? 0.35 : 0.15)); context.setLineWidth(0.6 * scale)
            context.strokeEllipse(in: circle.insetBy(dx: 0.3 * scale, dy: 0.3 * scale))
        }
        let title = style.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let available = rect.width - 180 * scale
        if !title.isEmpty && available > 30 {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateUIFontForLanguage(.system, 13 * scale, nil)!,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: dark ? 0.93 : 0.25, alpha: 1)
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: attributes))
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            let fitted = CTLineCreateTruncatedLine(line, available, .end, token) ?? line
            let bounds = CTLineGetBoundsWithOptions(fitted, .useGlyphPathBounds)
            context.textPosition = CGPoint(x: rect.midX - bounds.width / 2, y: rect.midY - bounds.midY)
            CTLineDraw(fitted, context)
        }
    }
    public static func decode(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw CaptureFailure.invalidImage }
        return try decode(source)
    }
    public static func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw CaptureFailure.invalidImage }
        return try decode(source)
    }
    private static func decode(_ source: CGImageSource) throws -> CGImage {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { throw CaptureFailure.invalidImage }
        guard width <= maximumPixels / height else { throw CaptureFailure.imageTooLarge }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: max(width, height), kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw CaptureFailure.invalidImage }
        return image
    }
    private static func grainImage() -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
        var seed: UInt32 = 92831
        for index in stride(from: 0, to: bytes.count, by: 4) {
            seed = 1664525 &* seed &+ 1013904223
            let value = UInt8((seed >> 24) & 255)
            bytes[index] = value; bytes[index + 1] = value; bytes[index + 2] = value; bytes[index + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
