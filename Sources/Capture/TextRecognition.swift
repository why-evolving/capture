import AppKit
import SwiftUI
import Vision
import CaptureCore

struct RecognizedLine: Identifiable, Sendable {
    let id = UUID()
    let text: String
    let bounds: UnitRect
    var isSensitive: Bool {
        let patterns = [#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#,
                        #"\b(?:sk-|ghp_|github_pat_|AKIA)[A-Za-z0-9_-]{12,}"#, #"(?<!\d)(?:\+?86[- ]?)?1[3-9]\d{9}(?!\d)"#,
                        #"(?<!\d)(?:\d[ -]?){15,19}(?!\d)"#]
        return patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }
}

struct RecognizedContent: Sendable {
    var lines: [RecognizedLine]
    var codes: [String]
    var text: String { lines.map(\.text).joined(separator: "\n") }
}

enum TextRecognition {
    static func recognize(_ image: CGImage) throws -> RecognizedContent {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"].filter { supported.contains($0) }
        let codes = VNDetectBarcodesRequest(); codes.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request, codes])
        let lines = (request.results ?? []).compactMap { observation -> RecognizedLine? in
            guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            let box = observation.boundingBox
            return RecognizedLine(text: text, bounds: UnitRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
        }
        return RecognizedContent(lines: lines, codes: (codes.results ?? []).compactMap(\.payloadStringValue))
    }
}

private typealias RecognitionState<Value> = SwiftUI.State<Value>

struct RecognitionView: View {
    @ObservedObject var document: CaptureDocument
    var pasteboard: NSPasteboard = .general
    @Environment(\.dismiss) private var dismiss
    @RecognitionState private var result: RecognizedContent?
    @RecognitionState private var text = ""
    @RecognitionState private var processing = true
    @RecognitionState private var message = ""
    @RecognitionState private var joinLines = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("提取文字与二维码", systemImage: "text.viewfinder").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("在本机识别当前截图内容，支持中英文。可校对后复制。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if processing { ProgressView("正在识别…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                TextEditor(text: $text).font(.system(size: 13)).padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2)))
                if let result, !result.codes.isEmpty {
                    ForEach(Array(result.codes.enumerated()), id: \.offset) { index, value in
                        HStack { Label("二维码 \(index + 1)", systemImage: "qrcode"); Text(value).lineLimit(1).truncationMode(.middle); Spacer(); Button("复制") { copy(value) } }.font(.system(size: 11))
                    }
                }
                if let result, result.lines.contains(where: \.isSensitive) {
                    let count = result.lines.filter(\.isSensitive).count
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("发现 \(count) 行可能包含敏感信息").font(.system(size: 12, weight: .medium))
                            Text("按整行实色遮挡，可撤销；分享前请检查。").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("遮挡这些行") { redact(result) }
                    }.padding(12).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                HStack {
                    Toggle("合并换行", isOn: $joinLines).toggleStyle(.checkbox).font(.system(size: 11))
                    Spacer()
                    Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("复制文字") { copy(joinLines ? text.replacingOccurrences(of: "\n", with: " ") : text) }
                        .buttonStyle(CaptureActionStyle(primary: true)).disabled(text.isEmpty).keyboardShortcut(.defaultAction)
                }
            }
        }.padding(24).frame(width: 640, height: 540).background(CaptureTheme.chrome).buttonStyle(CaptureActionStyle()).tint(CaptureTheme.accent)
        .task(id: document.edits) { await recognize() }
    }
    private func recognize() async {
        processing = true; result = nil; text = ""; message = ""
        let edits = document.edits
        do {
            let image = try await document.rendered(contentOnly: true)
            let value = try await Task.detached(priority: .userInitiated) { try TextRecognition.recognize(image) }.value
            guard !Task.isCancelled, document.edits == edits else { return }
            result = value; text = value.text
            if value.text.isEmpty { message = value.codes.isEmpty ? "未识别到文字，请尝试更清晰的截图。" : "已识别二维码。" }
            processing = false
        } catch {
            guard !Task.isCancelled else { return }
            processing = false; message = error.localizedDescription
        }
    }
    private func copy(_ value: String) {
        pasteboard.clearContents()
        message = pasteboard.setString(value, forType: .string) ? "已复制" : "复制失败，请重试。"
    }
    private func redact(_ result: RecognizedContent) {
        var edits = document.edits
        for line in result.lines where line.isSensitive {
            let bounds = line.bounds
            let start = edits.originalPoint(UnitPoint(max(0, bounds.x - 0.004), max(0, bounds.y - 0.005)))
            let end = edits.originalPoint(UnitPoint(min(1, bounds.x + bounds.width + 0.004), min(1, bounds.y + bounds.height + 0.005)))
            edits.annotations.append(Annotation(kind: .redact, start: start, end: end))
        }
        guard document.setEdits(edits) else { message = document.message ?? "没有可遮挡的行。"; return }
        document.message = "已遮挡候选行，请检查后再分享；⌘Z 可撤销。"; dismiss()
    }
}
