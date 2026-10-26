import CoreGraphics
import Foundation

public struct RenderLayout: Equatable, Sendable {
    public let canvasSize: CGSize
    public let cardRect: CGRect
    public let imageRect: CGRect
    public let headerHeight: Double

    public static func make(source: CGSize, style: CaptureStyle) throws -> RenderLayout {
        guard style.isValid else { throw CaptureFailure.invalidStyle }
        guard source.width.isFinite, source.height.isFinite, source.width > 0, source.height > 0 else { throw CaptureFailure.invalidImage }
        let factor = style.imageScale / 100
        // Layout is expressed in output pixels. Fractional centering or header
        // heights would resample even a 100% screenshot and soften its text.
        let image = CGSize(width: max(1, (source.width * factor).rounded()), height: max(1, (source.height * factor).rounded()))
        let header = style.windowFrame ? min(88, max(40, image.width / 18)).rounded() : 0
        let cardWidth = style.windowFrame ? max(image.width, ceil(120 * header / 44)) : image.width
        var canvas = CGSize(width: max(source.width, cardWidth) + style.padding * 2, height: source.height + style.padding * 2 + header)
        if let ratio = style.ratio.value {
            if canvas.width / canvas.height > ratio { canvas.height = canvas.width / ratio }
            else { canvas.width = canvas.height * ratio }
        }
        canvas.width = ceil(canvas.width); canvas.height = ceil(canvas.height)
        let cardHeight = image.height + header
        let y: Double
        switch style.position {
        case .top: y = canvas.height - style.padding - cardHeight
        case .center: y = (canvas.height - cardHeight) / 2
        case .bottom: y = style.padding
        }
        let x = ((canvas.width - cardWidth) / 2).rounded()
        let pixelY = y.rounded()
        return RenderLayout(canvasSize: canvas,
                            cardRect: CGRect(x: x, y: pixelY, width: cardWidth, height: cardHeight),
                            imageRect: CGRect(x: ((canvas.width - image.width) / 2).rounded(), y: pixelY, width: image.width, height: image.height),
                            headerHeight: header)
    }
}

public enum SelectionGeometry {
    /// Local selection coordinates use a flipped view, matching ScreenCaptureKit's top-left origin.
    public static func rectangle(from start: CGPoint, to requestedEnd: CGPoint, in bounds: CGRect, square: Bool = false) -> CGRect {
        var end = requestedEnd
        if square {
            let dx = end.x - start.x, dy = end.y - start.y
            let horizontal = dx < 0 ? start.x - bounds.minX : bounds.maxX - start.x
            let vertical = dy < 0 ? start.y - bounds.minY : bounds.maxY - start.y
            let side = max(0, min(max(abs(dx), abs(dy)), horizontal, vertical))
            end = CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        }
        return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(start.x - end.x), height: abs(start.y - end.y)).intersection(bounds)
    }
    public static func pixelSize(for selection: CGRect, backingScale: Double) -> CGSize {
        pixelRectangle(for: selection, backingScale: backingScale).size
    }
    /// Cover the selected pixels without a fractional origin or interpolation.
    public static func pixelRectangle(for selection: CGRect, backingScale: Double) -> CGRect {
        selection.applying(CGAffineTransform(scaleX: backingScale, y: backingScale)).integral
    }
}
