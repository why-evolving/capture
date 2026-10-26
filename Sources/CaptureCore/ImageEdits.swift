import Foundation
import CoreGraphics
import CoreText

/// Top-left normalized coordinates keep edits independent of preview resolution.
public struct UnitPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public var clamped: UnitPoint { UnitPoint(min(1, max(0, x)), min(1, max(0, y))) }
}

public struct UnitRect: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public init(_ first: UnitPoint, _ second: UnitPoint) {
        self.init(x: min(first.x, second.x), y: min(first.y, second.y), width: abs(first.x - second.x), height: abs(first.y - second.y))
    }
    public var center: UnitPoint { UnitPoint(x + width / 2, y + height / 2) }
    public func contains(_ point: UnitPoint) -> Bool { (x...x + width).contains(point.x) && (y...y + height).contains(point.y) }
    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1.00001 && y + height <= 1.00001
    }
    public func pixels(in size: CGSize) -> CGRect { CGRect(x: x * size.width, y: y * size.height, width: width * size.width, height: height * size.height) }
}

public enum AnnotationKind: String, Codable, CaseIterable, Sendable {
    case line, pen, spotlight, arrow, rectangle, ellipse, highlight, text, counter, redact, pixelate
    public var label: String {
        switch self {
        case .line: return "直线"; case .pen: return "画笔"; case .spotlight: return "聚光"; case .arrow: return "箭头"; case .rectangle: return "矩形"; case .ellipse: return "椭圆"; case .highlight: return "高亮"
        case .text: return "文字"; case .counter: return "序号"; case .redact: return "遮挡"; case .pixelate: return "马赛克"
        }
    }
    public var symbol: String {
        switch self {
        case .line: return "line.diagonal"; case .pen: return "pencil.tip"; case .spotlight: return "light.max"; case .arrow: return "arrow.up.right"; case .rectangle: return "rectangle"; case .ellipse: return "oval"; case .highlight: return "highlighter"
        case .text: return "textformat"; case .counter: return "1.circle"; case .redact: return "rectangle.fill"; case .pixelate: return "square.grid.3x3.fill"
        }
    }
}

public struct Annotation: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var kind: AnnotationKind
    public var start: UnitPoint
    public var end: UnitPoint
    public var color: RGBColor
    public var lineWidth: Double
    public var text: String
    public var points: [UnitPoint]? = nil
    public var textQuarterTurns = 0
    public var textFlipHorizontal = false
    public var textFlipVertical = false
    public init(kind: AnnotationKind, start: UnitPoint, end: UnitPoint, color: RGBColor = RGBColor(hex: "FF453A"), lineWidth: Double = 6, text: String = "") {
        self.kind = kind; self.start = start; self.end = end; self.color = color; self.lineWidth = lineWidth; self.text = text
    }
    public var bounds: UnitRect {
        let all = points ?? [start, end]
        return UnitRect(UnitPoint(all.map(\.x).min() ?? start.x, all.map(\.y).min() ?? start.y), UnitPoint(all.map(\.x).max() ?? end.x, all.map(\.y).max() ?? end.y))
    }
    public mutating func move(dx: Double, dy: Double) {
        let b = bounds
        let x = min(1-b.x-b.width, max(-b.x, dx)), y = min(1-b.y-b.height, max(-b.y, dy))
        start.x += x; start.y += y; end.x += x; end.y += y
        points = points?.map { UnitPoint($0.x+x, $0.y+y) }
    }
}

public struct ImageEdits: Codable, Equatable, Sendable {
    public var crop = UnitRect()
    public var quarterTurns = 0
    public var flipHorizontal = false
    public var flipVertical = false
    public var annotations: [Annotation] = []
    public init() {}
    public var isEmpty: Bool { self == ImageEdits() }
    public var isValid: Bool {
        crop.isValid && (0...3).contains(quarterTurns) && annotations.count <= 500 && annotations.allSatisfy { item in
            [item.start.x, item.start.y, item.end.x, item.end.y].allSatisfy { $0.isFinite && (0...1).contains($0) } &&
            (item.points?.count ?? 0) <= 4096 && (item.kind != .pen || (item.points?.count ?? 0) >= 2) &&
            (item.points ?? []).allSatisfy { $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) } &&
            item.color.isValid && item.lineWidth.isFinite && (1...40).contains(item.lineWidth) && item.text.count <= 2000 && (0...3).contains(item.textQuarterTurns)
        }
    }
    public func displayedSize(source: CGSize) -> CGSize {
        let size = crop.pixels(in: source).integral.intersection(CGRect(origin: .zero, size: source)).size
        let width = max(1, size.width), height = max(1, size.height)
        return quarterTurns % 2 == 0 ? CGSize(width: width, height: height) : CGSize(width: height, height: width)
    }
    public func displayPoint(_ original: UnitPoint) -> UnitPoint {
        var point = UnitPoint((original.x - crop.x) / crop.width, (original.y - crop.y) / crop.height)
        switch (quarterTurns % 4 + 4) % 4 {
        case 1: point = UnitPoint(1 - point.y, point.x)
        case 2: point = UnitPoint(1 - point.x, 1 - point.y)
        case 3: point = UnitPoint(point.y, 1 - point.x)
        default: break
        }
        if flipHorizontal { point.x = 1 - point.x }
        if flipVertical { point.y = 1 - point.y }
        return point
    }
    public func originalPoint(_ displayed: UnitPoint) -> UnitPoint {
        var point = displayed
        if flipHorizontal { point.x = 1 - point.x }
        if flipVertical { point.y = 1 - point.y }
        switch (quarterTurns % 4 + 4) % 4 {
        case 1: point = UnitPoint(point.y, 1 - point.x)
        case 2: point = UnitPoint(1 - point.x, 1 - point.y)
        case 3: point = UnitPoint(1 - point.y, point.x)
        default: break
        }
        return UnitPoint(crop.x + point.x * crop.width, crop.y + point.y * crop.height)
    }
    public mutating func crop(to displayed: UnitRect) {
        let first = originalPoint(UnitPoint(displayed.x, displayed.y)).clamped
        let second = originalPoint(UnitPoint(displayed.x + displayed.width, displayed.y + displayed.height)).clamped
        let next = UnitRect(first, second)
        if next.width > 0.005 && next.height > 0.005 { crop = next }
    }
}

public enum EditedImageRenderer {
    public static func render(_ source: CGImage, edits: ImageEdits) throws -> CGImage {
        try Task.checkCancellation()
        guard !edits.isEmpty else { return source }
        guard edits.isValid else { throw CaptureFailure.invalidImage }
        var annotated = source
        if !edits.annotations.isEmpty {
            let context = try makeContext(width: source.width, height: source.height)
            context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
            for annotation in edits.annotations { try Task.checkCancellation(); draw(annotation, in: context, size: CGSize(width: source.width, height: source.height), source: annotation.kind == .pixelate ? (context.makeImage() ?? source) : source) }
            guard let image = context.makeImage() else { throw CaptureFailure.encoding }
            annotated = image
        }
        let crop = edits.crop.pixels(in: CGSize(width: source.width, height: source.height)).integral.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard let cropped = annotated.cropping(to: crop) else { throw CaptureFailure.invalidImage }
        let turns = (edits.quarterTurns % 4 + 4) % 4
        if turns == 0 && !edits.flipHorizontal && !edits.flipVertical { return cropped }
        let width = turns % 2 == 0 ? cropped.width : cropped.height
        let height = turns % 2 == 0 ? cropped.height : cropped.width
        let context = try makeContext(width: width, height: height)
        context.translateBy(x: Double(width) / 2, y: Double(height) / 2)
        context.scaleBy(x: edits.flipHorizontal ? -1 : 1, y: edits.flipVertical ? -1 : 1)
        context.rotate(by: -Double(turns) * .pi / 2)
        let sourceWidth = Double(cropped.width), sourceHeight = Double(cropped.height)
        let drawingRect = CGRect(x: -sourceWidth / 2, y: -sourceHeight / 2, width: sourceWidth, height: sourceHeight)
        context.draw(cropped, in: drawingRect)
        guard let image = context.makeImage() else { throw CaptureFailure.encoding }
        return image
    }
    private static func makeContext(width: Int, height: Int) throws -> CGContext {
        guard width > 0, height > 0, width <= StyleCompositor.maximumPixels / height,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureFailure.imageTooLarge }
        return context
    }
    private static func draw(_ annotation: Annotation, in context: CGContext, size: CGSize, source: CGImage) {
        let start = CGPoint(x: annotation.start.x * size.width, y: (1 - annotation.start.y) * size.height)
        let end = CGPoint(x: annotation.end.x * size.width, y: (1 - annotation.end.y) * size.height)
        let bounds = annotation.bounds
        let rect = CGRect(x: bounds.x * size.width, y: (1 - bounds.y - bounds.height) * size.height, width: bounds.width * size.width, height: bounds.height * size.height)
        let width = min(40, max(1, annotation.lineWidth))
        context.saveGState(); defer { context.restoreGState() }
        context.setStrokeColor(annotation.color.cgColor); context.setFillColor(annotation.color.cgColor)
        context.setLineWidth(width); context.setLineCap(.round); context.setLineJoin(.round)
        switch annotation.kind {
        case .line:
            context.move(to: start); context.addLine(to: end); context.strokePath()
        case .pen:
            let points = annotation.points ?? []
            for (index, p) in points.enumerated() {
                let point = CGPoint(x: p.x * size.width, y: (1-p.y) * size.height)
                if index == 0 { context.move(to: point) } else { context.addLine(to: point) }
            }
            context.strokePath()
        case .spotlight:
            context.setFillColor(CGColor(gray: 0, alpha: 0.55))
            context.addRect(CGRect(origin: .zero, size: size)); context.addRect(rect); context.drawPath(using: .eoFill)
        case .arrow:
            let angle = atan2(end.y - start.y, end.x - start.x)
            let length = max(14, width * 3.6)
            context.move(to: start); context.addLine(to: end); context.strokePath()
            context.move(to: CGPoint(x: end.x - length * cos(angle - .pi / 6), y: end.y - length * sin(angle - .pi / 6)))
            context.addLine(to: end)
            context.addLine(to: CGPoint(x: end.x - length * cos(angle + .pi / 6), y: end.y - length * sin(angle + .pi / 6))); context.strokePath()
        case .rectangle: context.stroke(rect)
        case .ellipse: context.strokeEllipse(in: rect)
        case .highlight: context.setAlpha(0.32); context.fill(rect)
        case .redact: context.setFillColor(CGColor(gray: 0.06, alpha: 1)); context.fill(rect.integral)
        case .pixelate:
            let native = bounds.pixels(in: size).integral.intersection(CGRect(origin: .zero, size: size))
            if let region = source.cropping(to: native),
               let small = try? makeContext(width: max(1, Int(native.width / 18)), height: max(1, Int(native.height / 18))) {
                small.interpolationQuality = .low
                small.draw(region, in: CGRect(x: 0, y: 0, width: small.width, height: small.height))
                if let image = small.makeImage() { context.interpolationQuality = .none; context.draw(image, in: rect) }
            }
        case .text:
            let font = max(16, width * 5)
            let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateUIFontForLanguage(.emphasizedSystem, font, nil)!, NSAttributedString.Key(kCTForegroundColorAttributeName as String): annotation.color.cgColor]
            let setter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: annotation.text, attributes: attributes))
            let localWidth = annotation.textQuarterTurns % 2 == 0 ? rect.width : rect.height
            let localHeight = annotation.textQuarterTurns % 2 == 0 ? rect.height : rect.width
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: Double(annotation.textQuarterTurns) * .pi / 2)
            context.scaleBy(x: annotation.textFlipHorizontal ? -1 : 1, y: annotation.textFlipVertical ? -1 : 1)
            let box = CGRect(x: -localWidth / 2, y: -localHeight / 2, width: max(localWidth, font * 3), height: max(localHeight, font * 1.5))
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: box, transform: nil), nil), context)
        case .counter:
            let diameter = max(32, width * 8)
            let circle = CGRect(x: start.x - diameter / 2, y: start.y - diameter / 2, width: diameter, height: diameter)
            context.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: CGColor(gray: 0, alpha: 0.2)); context.fillEllipse(in: circle)
            context.setShadow(offset: .zero, blur: 0)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: annotation.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateUIFontForLanguage(.emphasizedSystem, diameter * 0.52, nil)!, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)]))
            let textBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            context.translateBy(x: start.x, y: start.y)
            context.rotate(by: Double(annotation.textQuarterTurns) * .pi / 2)
            context.scaleBy(x: annotation.textFlipHorizontal ? -1 : 1, y: annotation.textFlipVertical ? -1 : 1)
            context.textPosition = CGPoint(x: -textBounds.midX, y: -textBounds.midY); CTLineDraw(line, context)
        }
    }
}
