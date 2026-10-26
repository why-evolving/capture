import AppKit
import SwiftUI
import CaptureCore
import Combine

struct CollageItem: Identifiable { let id = UUID(); let image: CGImage; let name: String }
@MainActor final class CollageModel: ObservableObject {
    @Published var items: [CollageItem]
    @Published var options = CollageOptions()
    @Published var preview: NSImage?
    @Published var error: String?
    @Published var rendering = false
    @Published var generating = false
    private var task: Task<Void, Never>?
    private var generation = 0
    init(images: [CGImage], names: [String]) { items = zip(images,names).map { CollageItem(image: $0.0, name: $0.1) } }
    var canGenerate: Bool { (2...12).contains(items.count) && !generating && error == nil }
    func move(_ id: UUID, offset: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }), items.indices.contains(i+offset) else { return }
        items.swapAt(i,i+offset); refresh()
    }
    func remove(_ id: UUID) { items.removeAll { $0.id == id }; refresh() }
    func refresh() {
        generation += 1; let token = generation
        task?.cancel(); error = nil
        guard items.count >= 2 else { preview = nil; rendering = false; return }
        let images = items.map(\.image), options = options
        rendering = true
        task = Task {
            do {
                try await Task.sleep(for: .milliseconds(80))
                let worker = Task.detached(priority: .userInitiated) { try CollageLayout.render(images, options: options, previewLimit: 1800) }
                let image = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, generation == token else { return }
                preview = NSImage(cgImage: image, size: CGSize(width: image.width,height: image.height)); rendering = false
            } catch { if !Task.isCancelled && generation == token { self.error = error.localizedDescription; rendering = false } }
        }
    }
    func generate(_ completion: @escaping (CGImage) -> Void) {
        guard canGenerate else { return }; generating = true; task?.cancel(); generation += 1
        let images = items.map(\.image), options = options
        task = Task {
            defer { generating = false }
            do {
                let worker = Task.detached(priority: .userInitiated) { try CollageLayout.render(images, options: options) }
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled else { return }; completion(result)
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func cancel() { generation += 1; task?.cancel(); rendering = false }
}
struct CollageView: View {
    @ObservedObject var model: CollageModel
    let onCreate: (CGImage) -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) { Text("拼接图片").font(.system(size: 18,weight: .semibold)); Text("保留原始像素 · 按列表顺序排列 · 原文件保持完整").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let layout = try? CollageLayout.make(sizes:model.items.map { CGSize(width:$0.image.width,height:$0.image.height) },options:model.options) {
                    Text("\(Int(layout.size.width)) × \(Int(layout.size.height)) px").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Button(model.generating ? "生成中…" : "生成图片") { model.generate(onCreate) }.buttonStyle(CaptureActionStyle(primary: true)).disabled(!model.canGenerate)
            }.padding(24)
            Divider()
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading,spacing: 16) {
                        CaptureSegments("排列",selection:$model.options.direction,options:CollageDirection.allCases.map { ($0,$0.label) })
                        HStack { Text("间距"); Spacer(); Text("\(model.options.gap) px").monospacedDigit() }.font(.caption)
                        CaptureSlider(value: Binding(get: { Double(model.options.gap) },set: { model.options.gap = Int($0) }),in: 0...80).accessibilityLabel("拼图间距")
                        HStack { Text("底色").font(.caption); Spacer(); CaptureColorWell("底色",selection: Binding(get: { model.options.background.color },set: { model.options.background = RGBColor($0) })) }
                        Divider()
                        Text("\(model.items.count) 张图片").font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(model.items.enumerated()),id: \.element.id) { index,item in
                            HStack(spacing: 8) {
                                Text("\(index+1)").font(.caption).foregroundStyle(.secondary).frame(width: 15)
                                Image(nsImage: NSImage(cgImage:item.image,size:CGSize(width:item.image.width,height:item.image.height))).resizable().scaledToFit().frame(width:42,height:34)
                                Text(item.name).font(.caption).lineLimit(2); Spacer(minLength:0)
                                VStack(spacing:6) {
                                    Button { model.move(item.id,offset:-1) } label: { Image(systemName:"chevron.up") }.disabled(index == 0).accessibilityLabel("上移 \(item.name)")
                                    Button { model.move(item.id,offset:1) } label: { Image(systemName:"chevron.down") }.disabled(index == model.items.count-1).accessibilityLabel("下移 \(item.name)")
                                }
                                Button { model.remove(item.id) } label: { Image(systemName:"xmark") }.accessibilityLabel("移除 \(item.name)")
                            }.buttonStyle(.plain).padding(10).background(.quaternary.opacity(0.4),in:RoundedRectangle(cornerRadius:9))
                        }
                    }.padding(20)
                }.frame(width:300).disabled(model.generating)
                Divider()
                ZStack {
                    CaptureTheme.canvas
                    if let preview = model.preview { Image(nsImage:preview).resizable().scaledToFit().padding(28) }
                    if let error = model.error { Text(error).foregroundStyle(.orange).padding().background(.regularMaterial,in:RoundedRectangle(cornerRadius:10)) }
                    if model.items.count < 2 { Text("至少需要两张图片；关闭后可重新选择。").foregroundStyle(.secondary) }
                    if model.rendering || model.generating { ProgressView().padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10)) }
                }
            }
        }.buttonStyle(CaptureActionStyle()).tint(CaptureTheme.accent).onAppear { model.refresh() }.onChange(of:model.options) { _,_ in model.refresh() }.onDisappear { model.cancel() }
    }
}
