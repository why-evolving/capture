import SwiftUI
import AppKit
import CaptureCore

enum MarkupTool: Equatable {
    case select, crop, annotation(AnnotationKind)
}
private typealias CanvasState<Value> = SwiftUI.State<Value>

struct AnnotationCanvas: View {
    @ObservedObject var document: CaptureDocument
    let tool: MarkupTool
    let color: CaptureCore.RGBColor
    let lineWidth: Double
    let text: String
    @Binding var selected: UUID?
    @CanvasState private var start: CaptureCore.UnitPoint?
    @CanvasState private var end: CaptureCore.UnitPoint?
    @CanvasState private var pathPoints: [CaptureCore.UnitPoint] = []
    var body: some View {
        GeometryReader { geometry in
            if let image = document.contentPreview {
                let imageSize = image.size
                let factor = min(geometry.size.width / imageSize.width, geometry.size.height / imageSize.height)
                let size = CGSize(width: imageSize.width * factor, height: imageSize.height * factor)
                ZStack {
                    Image(nsImage: image).resizable().interpolation(.high).frame(width: size.width, height: size.height)
                    Canvas { context, canvasSize in
                        if let id = selected, let item = document.edits.annotations.first(where: { $0.id == id }) {
                            let first = document.edits.displayPoint(CaptureCore.UnitPoint(item.bounds.x, item.bounds.y)), last = document.edits.displayPoint(CaptureCore.UnitPoint(item.bounds.x + item.bounds.width, item.bounds.y + item.bounds.height))
                            let rect = pixelRect(first, last, in: canvasSize).insetBy(dx: -5, dy: -5)
                            context.stroke(Path(rect), with: .color(CaptureTheme.accent), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        }
                        if let start, let end {
                            let rect = pixelRect(start, end, in: canvasSize)
                            let stroke = StrokeStyle(lineWidth: 2, dash: tool == .crop ? [6, 4] : [])
                            switch tool {
                            case .select: break
                            case .crop:
                                var shade = Path(CGRect(origin: .zero, size: canvasSize)); shade.addRect(rect)
                                context.fill(shade, with: .color(.black.opacity(0.35)), style: FillStyle(eoFill: true))
                                context.stroke(Path(rect), with: .color(.white), style: stroke)
                            case .annotation(.pen):
                                var path = Path()
                                for (index, p) in pathPoints.enumerated() { let point = CGPoint(x: p.x * canvasSize.width, y: p.y * canvasSize.height); if index == 0 { path.move(to: point) } else { path.addLine(to: point) } }
                                context.stroke(path, with: .color(color.color), style: StrokeStyle(lineWidth: max(1, lineWidth * factor), lineCap: .round, lineJoin: .round))
                            case .annotation(.arrow), .annotation(.line):
                                var path = Path(); path.move(to: CGPoint(x: start.x * canvasSize.width, y: start.y * canvasSize.height)); path.addLine(to: CGPoint(x: end.x * canvasSize.width, y: end.y * canvasSize.height))
                                context.stroke(path, with: .color(color.color), lineWidth: 2)
                            case .annotation(let kind):
                                if kind == .ellipse { context.stroke(Path(ellipseIn: rect), with: .color(color.color), lineWidth: 2) }
                                else if kind == .redact || kind == .pixelate { context.fill(Path(rect), with: .color(.black.opacity(0.8))) }
                                else { context.stroke(Path(rect), with: .color(color.color), style: stroke) }
                            }
                        }
                    }.allowsHitTesting(false)
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            if start == nil {
                                start = point(value.startLocation, size)
                                if tool == .select { selected = hit(point(value.startLocation, size)) }
                            }
                            end = point(value.location, size)
                            if tool == .annotation(.pen), pathPoints.count < 4096, let end, pathPoints.last != end { pathPoints.append(end) }
                        }.onEnded { value in finish(from: point(value.startLocation, size), to: point(value.location, size)) })
                }.frame(width: size.width, height: size.height)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.padding(28)
        .onChange(of: tool) { _, _ in start = nil; end = nil; pathPoints = []; selected = nil }
        .onChange(of: document.edits) { _, _ in
            if let selected, !document.edits.annotations.contains(where: { $0.id == selected }) { self.selected = nil }
        }
    }
    private func point(_ value: CGPoint, _ size: CGSize) -> CaptureCore.UnitPoint { CaptureCore.UnitPoint(value.x / max(1, size.width), value.y / max(1, size.height)).clamped }
    private func pixelRect(_ first: CaptureCore.UnitPoint, _ last: CaptureCore.UnitPoint, in size: CGSize) -> CGRect { UnitRect(first, last).pixels(in: size) }
    private func hit(_ point: CaptureCore.UnitPoint) -> UUID? {
        document.edits.annotations.reversed().first { item in
            let a = document.edits.displayPoint(CaptureCore.UnitPoint(item.bounds.x, item.bounds.y)), b = document.edits.displayPoint(CaptureCore.UnitPoint(item.bounds.x + item.bounds.width, item.bounds.y + item.bounds.height))
            let rect = UnitRect(a, b)
            return point.x >= rect.x - 0.025 && point.x <= rect.x + max(0.04, rect.width) + 0.025 && point.y >= rect.y - 0.025 && point.y <= rect.y + max(0.04, rect.height) + 0.025
        }?.id
    }
    private func finish(from first: CaptureCore.UnitPoint, to last: CaptureCore.UnitPoint) {
        defer { start = nil; end = nil; pathPoints = [] }
        let distance = hypot(first.x - last.x, first.y - last.y)
        switch tool {
        case .select:
            guard distance > 0.002, let selected, let index = document.edits.annotations.firstIndex(where: { $0.id == selected }) else { return }
            var edits = document.edits
            let origin = edits.originalPoint(first), destination = edits.originalPoint(last)
            var item = edits.annotations[index]
            item.move(dx: destination.x - origin.x, dy: destination.y - origin.y)
            edits.annotations[index] = item; document.setEdits(edits)
        case .crop:
            guard distance > 0.02 else { return }
            var edits = document.edits; edits.crop(to: UnitRect(first, last)); document.setEdits(edits)
        case .annotation(let kind):
            guard (kind == .pen && pathPoints.count >= 2) || distance > 0.008 || kind == .counter || kind == .text else { return }
            let last = distance < 0.008 ? CaptureCore.UnitPoint(min(1, first.x + 0.35), min(1, first.y + 0.12)) : last
            let count = (document.edits.annotations.filter { $0.kind == .counter }.compactMap { Int($0.text) }.max() ?? 0) + 1
            var item = Annotation(kind: kind, start: document.edits.originalPoint(first), end: document.edits.originalPoint(kind == .counter ? first : last), color: color, lineWidth: lineWidth, text: kind == .counter ? String(count) : String(text.prefix(2000)))
            if kind == .pen { item.points = pathPoints.map { document.edits.originalPoint($0).clamped } }
            item.textQuarterTurns = document.edits.quarterTurns
            item.textFlipHorizontal = document.edits.flipHorizontal; item.textFlipVertical = document.edits.flipVertical
            if document.addAnnotation(item) { selected = item.id }
        }
    }
}
