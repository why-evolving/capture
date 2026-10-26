import AppKit
import CaptureCore
import Combine
import UniformTypeIdentifiers

@MainActor
final class CaptureDocument: ObservableObject, Identifiable {
    let id: UUID
    let original: CGImage
    let isSample: Bool
    let createdAt: Date
    private let initialStyle: CaptureStyle
    private let initialUseStyle: Bool
    @Published private(set) var style: CaptureStyle
    @Published private(set) var useStyle: Bool
    @Published private(set) var edits = ImageEdits()
    @Published var showOriginal = false
    @Published var selectedAnnotationID: UUID?
    @Published private(set) var preview: NSImage?
    @Published private(set) var contentPreview: NSImage?
    @Published private(set) var rendering = false
    @Published var message: String?
    @Published var showingRecognition = false
    @Published var outputFormat: ImageFormat = .png { didSet { onContentChange?() } }
    @Published var outputScale = 1.0 { didSet { onContentChange?() } }
    @Published var jpegQuality = 0.9 { didSet { onContentChange?() } }
    @Published var filename = "Screenshot" { didSet { onContentChange?() } }
    @Published var copiedImage: NSImage?
    @Published var copyLabel = ""
    @Published var copiedDimensions = ""
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var favorite = false { didSet { onContentChange?() } }
    var onContentChange: (() -> Void)?
    var onStyleChange: ((CaptureStyle) -> Void)?
    private var history: [(CaptureStyle, Bool, ImageEdits)]
    private var historyIndex = 0
    private var originalPNGCache: Data?
    private var renderTask: Task<Void, Never>?
    private var revision = 0
    private var grouping = false
    private var groupRecorded = false

    init(image: CGImage, style: CaptureStyle, useStyle: Bool, isSample: Bool = false, id: UUID = UUID(), createdAt: Date = Date(), edits: ImageEdits = ImageEdits()) {
        self.id = id; self.createdAt = createdAt; self.edits = edits
        original = image; self.style = style; self.useStyle = useStyle; self.isSample = isSample
        initialStyle = style; initialUseStyle = useStyle
        history = [(style, useStyle, edits)]
        filename = "Capture-" + DateFormatter.captureName.string(from: createdAt)
        requestPreview()
    }
    var dimensions: CGSize {
        let size = edits.displayedSize(source: CGSize(width: original.width, height: original.height))
        if !useStyle { return size }
        return (try? RenderLayout.make(source: size, style: style).canvasSize) ?? .zero
    }
    var dimensionLabel: String { "\(Int(dimensions.width)) × \(Int(dimensions.height)) px" }
    var estimatedMemoryBytes: Int {
        original.bytesPerRow * original.height + (originalPNGCache?.count ?? 0) + [preview, contentPreview, copiedImage].compactMap { $0 }.reduce(0) { total, image in
            total + Int(image.size.width * image.size.height) * 4
        }
    }
    var exportLabel: String {
        "\(Int((dimensions.width * outputScale).rounded())) × \(Int((dimensions.height * outputScale).rounded())) px"
    }
    func setStyle(_ value: CaptureStyle) { change(style: value, enabled: true) }
    func enableBeauty() { if !useStyle { change(style: style, enabled: true) } }
    func change(style: CaptureStyle, enabled: Bool) {
        guard style.isValid, style != self.style || enabled != useStyle else { return }
        self.style = style; useStyle = enabled; showOriginal = false
        recordHistory(); onStyleChange?(style); requestPreview()
    }
    private func recordHistory() {
        if grouping && groupRecorded {
            history[historyIndex] = (style, useStyle, edits); updateHistoryState(); return
        }
        history = Array(history.prefix(historyIndex + 1)); history.append((style, useStyle, edits))
        if history.count > 80 { history.removeFirst() }
        historyIndex = history.count - 1
        updateHistoryState()
        if grouping { groupRecorded = true }
    }
    func groupChanges(_ active: Bool) { grouping = active; groupRecorded = false }
    @discardableResult
    func setEdits(_ value: ImageEdits) -> Bool {
        guard value.isValid else { message = "无法应用内容编辑：最多 500 个标注，文字最多 2000 字。"; return false }
        guard value != edits else { return false }
        edits = value; showOriginal = false; recordHistory(); requestPreview()
        if let selectedAnnotationID, !edits.annotations.contains(where: { $0.id == selectedAnnotationID }) { self.selectedAnnotationID = nil }
        return true
    }
    @discardableResult
    func addAnnotation(_ annotation: Annotation) -> Bool {
        var next = edits; next.annotations.append(annotation); return setEdits(next)
    }
    func deleteAnnotation(_ id: UUID) {
        var next = edits; next.annotations.removeAll { $0.id == id }; setEdits(next)
    }
    func rotate() { var next = edits; next.quarterTurns = (next.quarterTurns + 1) % 4; setEdits(next) }
    func flip() { var next = edits; next.flipHorizontal.toggle(); setEdits(next) }
    func removeEdits() { setEdits(ImageEdits()) }
    func suggestBackground() {
        guard let context = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 160,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return }
        context.draw(original, in: CGRect(x: 0, y: 0, width: 40, height: 40))
        var red = 0.0, green = 0.0, blue = 0.0, weight = 0.0
        for pixel in 0..<1600 where bytes[pixel * 4 + 3] > 200 {
            let r = Double(bytes[pixel * 4]) / 255, g = Double(bytes[pixel * 4 + 1]) / 255, b = Double(bytes[pixel * 4 + 2]) / 255
            let saturation = max(r, g, b) - min(r, g, b)
            guard saturation > 0.05 else { continue }
            red += r * saturation; green += g * saturation; blue += b * saturation; weight += saturation
        }
        let sampled = weight > 0 ? NSColor(srgbRed: red / weight, green: green / weight, blue: blue / weight, alpha: 1) : NSColor(CaptureTheme.accent)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        sampled.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let a = NSColor(calibratedHue: hue, saturation: min(0.5, saturation * 0.45 + 0.12), brightness: 0.9, alpha: 1).usingColorSpace(.sRGB)!
        let b = NSColor(calibratedHue: (hue + 0.07).truncatingRemainder(dividingBy: 1), saturation: min(0.25, saturation * 0.2 + 0.06), brightness: 0.99, alpha: 1).usingColorSpace(.sRGB)!
        var next = style; next.background = .gradient
        next.firstColor = CaptureCore.RGBColor(red: a.redComponent, green: a.greenComponent, blue: a.blueComponent)
        next.secondColor = CaptureCore.RGBColor(red: b.redComponent, green: b.greenComponent, blue: b.blueComponent)
        setStyle(next)
    }
    func undo() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1; restoreHistory()
    }
    func redo() {
        guard historyIndex + 1 < history.count else { return }
        historyIndex += 1; restoreHistory()
    }
    private func restoreHistory() {
        grouping = false; groupRecorded = false; showOriginal = false
        (style, useStyle, edits) = history[historyIndex]
        if let selectedAnnotationID, !edits.annotations.contains(where: { $0.id == selectedAnnotationID }) { self.selectedAnnotationID = nil }
        updateHistoryState(); onStyleChange?(style); requestPreview()
    }
    private func updateHistoryState() { canUndo = historyIndex > 0; canRedo = historyIndex + 1 < history.count }
    func reset() { change(style: initialStyle, enabled: initialUseStyle) }
    func requestPreview() {
        onContentChange?()
        revision += 1
        let token = revision
        renderTask?.cancel()
        let source = original, style = useStyle ? style : nil, edits = edits
        rendering = true
        renderTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 35_000_000)
                guard !Task.isCancelled else { return }
                let worker = Task.detached(priority: .userInitiated) {
                    let content = try EditedImageRenderer.render(source, edits: edits)
                    try Task.checkCancellation()
                    // Keep enough pixels for the editor on a Retina display.
                    // Copy/export always render independently from the original.
                    return (try StyleCompositor.render(content, style: style, previewLimit: 2800),
                            try StyleCompositor.render(content, style: nil, previewLimit: 2800))
                }
                let pair = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, let self, self.revision == token else { return }
                self.preview = NSImage(cgImage: pair.0, size: NSSize(width: pair.0.width, height: pair.0.height))
                self.contentPreview = NSImage(cgImage: pair.1, size: NSSize(width: pair.1.width, height: pair.1.height))
                self.rendering = false
            } catch {
                guard let self, self.revision == token, !Task.isCancelled else { return }
                self.message = error.localizedDescription; self.rendering = false
            }
        }
    }
    func rendered(originalOnly: Bool = false, scale: Double? = nil, opaque: Bool = false, contentOnly: Bool = false) async throws -> CGImage {
        let source = original
        // Comparing the original is view-only. Unedited output is always explicit.
        let raw = originalOnly
        let applied = raw || !useStyle || contentOnly ? nil : style
        let changes = raw ? ImageEdits() : edits
        let scale = raw || contentOnly ? 1 : (scale ?? outputScale)
        let worker = Task.detached(priority: .userInitiated) {
            let content = try EditedImageRenderer.render(source, edits: changes)
            return try StyleCompositor.render(content, style: applied, scale: scale, opaque: opaque)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = filename.replacingOccurrences(of: "/", with: "-") + ".png"
        let source = original, changes = edits, style = useStyle ? style : nil, scale = outputScale
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            let task = Task.detached(priority: .userInitiated) {
                defer { progress.completedUnitCount = 1 }
                do {
                    let image = try EditedImageRenderer.render(source, edits: changes)
                    let result = try StyleCompositor.render(image, style: style, scale: scale)
                    completion(try StyleCompositor.encode(result), nil)
                } catch { completion(nil, error) }
            }
            progress.cancellationHandler = { task.cancel() }
            return progress
        }
        return provider
    }
    func projectSnapshot() async throws -> CaptureProject {
        let source = original
        var value = CaptureProject(id: id, createdAt: createdAt, name: filename, favorite: favorite, originalPNG: Data(), style: style, useStyle: useStyle, edits: edits, format: outputFormat, scale: outputScale, quality: jpegQuality)
        if let cached = originalPNGCache { value.originalPNG = cached }
        else {
            let worker = Task.detached(priority: .utility) { try StyleCompositor.encode(source) }
            let data = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            originalPNGCache = data; value.originalPNG = data
        }
        try Task.checkCancellation()
        return value
    }
    static func restore(_ project: CaptureProject, image: CGImage) -> CaptureDocument {
        let document = CaptureDocument(image: image, style: project.style, useStyle: project.useStyle, id: project.id, createdAt: project.createdAt, edits: project.edits)
        document.originalPNGCache = project.originalPNG
        document.filename = project.name; document.favorite = project.favorite
        document.outputFormat = project.format; document.outputScale = project.scale; document.jpegQuality = project.quality
        return document
    }
    func originalImage() -> NSImage { NSImage(cgImage: original, size: NSSize(width: original.width, height: original.height)) }
}

extension DateFormatter {
    static let captureName: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
