import AppKit
import SwiftUI
import CaptureCore

@MainActor
final class PinController: NSObject, NSWindowDelegate {
    private var windows: [Int: NSWindow] = [:]
    @discardableResult
    func show(_ image: CGImage, document: CaptureDocument, app: AppController) -> Bool {
        guard windows.count < 8 else { return false }
        let width = min(600, max(240, Double(image.width) / 2))
        let height = min(600, max(160, width * Double(image.height) / Double(image.width)))
        let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: width, height: height + 42),
                             styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "置顶 · " + document.filename
        window.level = .floating; window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false; window.backgroundColor = .clear
        window.minSize = CGSize(width: 180, height: 140); window.delegate = self
        window.contentView = NSHostingView(rootView: PinnedImageView(image: image, copy: { app.copyPinnedImage(image) }, close: { [weak window] in window?.close() }, clickThrough: { [weak window] in window?.ignoresMouseEvents = true }))
        window.center(); windows[window.windowNumber] = window; window.orderFrontRegardless()
        return true
    }
    var allInteractive: Bool { windows.values.allSatisfy { !$0.ignoresMouseEvents } }
    func enableClickThrough() { windows.values.forEach { $0.ignoresMouseEvents = true } }
    func restoreInteraction() { windows.values.forEach { $0.ignoresMouseEvents = false } }
    var count: Int { windows.count }
    func closeAll() { let current = Array(windows.values); windows.removeAll(); current.forEach { $0.close() } }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { windows.removeValue(forKey: window.windowNumber) }
    }
}

private typealias LibraryState<Value> = SwiftUI.State<Value>
struct PinnedImageView: View {
    let image: CGImage
    let copy: () -> Bool
    let close: () -> Void
    var clickThrough: () -> Void = {}
    @LibraryState private var opacity = 1.0
    @LibraryState private var copied = false
    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)))
                .resizable().interpolation(.high).scaledToFit().opacity(opacity).frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 9) {
                Image(systemName: "circle.lefthalf.filled").help("图片透明度")
                CaptureSlider(value: $opacity, in: 0.2...1).controlSize(.mini).frame(maxWidth: 120).accessibilityLabel("图片透明度")
                Spacer()
                Button { copied = copy() } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }.help("复制置顶的这张图片").accessibilityLabel("复制置顶图片")
                Button(action: clickThrough) { Image(systemName: "cursorarrow.rays") }.help("鼠标穿透；菜单栏 → 置顶图片 → 恢复交互").accessibilityLabel("启用鼠标穿透")
                Button(action: close) { Image(systemName: "xmark") }.help("关闭置顶").accessibilityLabel("关闭置顶图片")
            }.font(.system(size: 11)).buttonStyle(.plain).padding(10).background(.regularMaterial)
        }
    }
}

struct RecentCapturesView: View {
    @ObservedObject var app: AppController
    var body: some View { CaptureLibraryView(app:app,library:app.library) }
}
private struct CaptureLibraryView: View {
    @ObservedObject var app: AppController
    @ObservedObject var library: LibraryStore
    @LibraryState private var confirmingClear = false
    @LibraryState private var saved = false
    @LibraryState private var search = ""
    @LibraryState private var favoritesOnly = false
    private var recent: [CaptureDocument] { app.recentDocuments.filter { matches($0.filename,$0.favorite) } }
    private var persisted: [LibraryEntry] { library.entries.filter { matches($0.name,$0.favorite) } }
    private func matches(_ name:String,_ favorite:Bool) -> Bool { (!favoritesOnly || favorite) && (search.isEmpty || name.localizedCaseInsensitiveContains(search)) }
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {
                VStack(alignment:.leading,spacing:5) {
                    Text("截图库").font(.system(size:22,weight:.semibold))
                    Text(saved ? "本机项目包含原图；受保留时间与容量上限约束。" : "本次运行最近 12 张；重要图片请保存项目或导出。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(); Button("清空…") { confirmingClear = true }.disabled(saved ? library.entries.isEmpty || library.working : app.recentDocuments.isEmpty)
            }.padding(22)
            HStack(spacing:12) {
                CaptureSegments("来源",selection:$saved,options:[(false,"本次运行"),(true,"本地历史")]).frame(width:210)
                TextField("搜索名称",text:$search).textFieldStyle(CaptureFieldStyle())
                Toggle(isOn:$favoritesOnly) { Label("收藏",systemImage: favoritesOnly ? "star.fill" : "star") }.toggleStyle(.button)
            }.padding(.horizontal,22).padding(.bottom,18)
            Divider()
            if let error = library.error { Text(error).font(.caption).foregroundStyle(.orange).padding(12) }
            if saved ? persisted.isEmpty : recent.isEmpty {
                VStack(spacing:12) {
                    Image(systemName:"photo.stack").font(.system(size:38,weight:.light)).foregroundStyle(CaptureTheme.accent)
                    Text(search.isEmpty && !favoritesOnly ? "还没有截图" : "没有匹配的截图").font(.headline)
                    if !search.isEmpty || favoritesOnly { Button("清除筛选") { search = ""; favoritesOnly = false } }
                    else if saved { Text("在设置中开启本地历史，新截图将自动保存。").font(.caption).foregroundStyle(.secondary); Button("打开设置") { app.showSettings() } }
                    else { Button("区域截图") { app.beginCapture() }.buttonStyle(CaptureActionStyle(primary: true)) }
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing:10) {
                        if saved { ForEach(persisted) { entry in savedRow(entry) } }
                        else { ForEach(recent) { document in RecentCaptureRow(document:document,app:app) } }
                    }.padding(20)
                }
            }
        }.frame(minWidth:660,minHeight:420).background(CaptureTheme.chrome).buttonStyle(CaptureActionStyle()).tint(CaptureTheme.accent)
        .confirmationDialog(saved ? "清空本地历史？" : "清空本次运行的最近截图？",isPresented:$confirmingClear,titleVisibility:.visible) {
            Button("确认清空",role:.destructive) { if saved { library.clear() } else { app.clearRecent() } }
            Button("取消",role:.cancel) {}
        } message: { Text(saved ? "删除本机历史中的项目。已导出的文件和打开的编辑器保留。" : "未保存且未打开的图片将无法从此处找回。") }
    }
    private func savedRow(_ entry:LibraryEntry) -> some View { SavedCaptureRow(entry:entry, app:app, library:library) }
}
private struct SavedCaptureRow: View {
    let entry: LibraryEntry
    @ObservedObject var app: AppController
    @ObservedObject var library: LibraryStore
    @LibraryState private var preview: NSImage?
    var body: some View {
        HStack(spacing:14) {
            Group { if let preview { Image(nsImage:preview).resizable().scaledToFit() } else { Image(systemName:"doc.richtext").font(.system(size:25)).foregroundStyle(CaptureTheme.accent) } }.frame(width:90,height:62)
            VStack(alignment:.leading,spacing:5) { Text(entry.name).font(.system(size:13,weight:.medium)).lineLimit(1); Text(entry.modifiedAt,format:.dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button {
                if let document = app.recentDocuments.first(where:{ $0.id == entry.id }) { document.favorite = !entry.favorite }
                library.update(entry.id, favorite:!entry.favorite)
            } label: { Image(systemName:entry.favorite ? "star.fill" : "star").foregroundStyle(entry.favorite ? Color.orange : Color.secondary) }.buttonStyle(.plain).accessibilityLabel(entry.favorite ? "取消收藏" : "收藏")
            Button("继续编辑") { app.openLibrary(entry.id) }
            Menu {
                Button("重命名…") {
                    let alert = NSAlert(); alert.messageText = "重命名历史项目"; alert.addButton(withTitle:"保存"); alert.addButton(withTitle:"取消")
                    let field = CapturePanelField(input:entry.name); field.frame = CGRect(x:0,y:0,width:280,height:24); alert.accessoryView = field; alert.window.initialFirstResponder = field
                    while alert.runModal() == .alertFirstButtonReturn {
                        let name = field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
                        if !name.isEmpty && name.count <= 200 {
                            app.recentDocuments.first(where:{ $0.id == entry.id })?.filename = name
                            library.update(entry.id,name:name); break
                        }; alert.informativeText = "请输入 1–200 个字符。"
                    }
                }
                Button("从历史移除",role:.destructive) { library.remove(entry.id) }
            } label: { Image(systemName:"ellipsis") }.fixedSize().accessibilityLabel("历史项目操作")
        }.padding(14).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:12))
        .task(id:entry.modifiedAt) { preview = await library.thumbnail(entry.id) }
    }
}

private struct RecentCaptureRow: View {
    @ObservedObject var document: CaptureDocument
    @ObservedObject var app: AppController
    var body: some View {
        HStack(spacing: 16) {
            Image(nsImage: document.preview ?? document.originalImage()).resizable().scaledToFit()
                .frame(width: 100, height: 68).background(CaptureTheme.canvas, in: RoundedRectangle(cornerRadius: 6))
                .onDrag { document.itemProvider() }
            VStack(alignment: .leading, spacing: 6) {
                Text(document.filename).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(document.createdAt, style: .time).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(document.dimensionLabel).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { document.favorite.toggle() } label: { Image(systemName:document.favorite ? "star.fill" : "star").foregroundStyle(document.favorite ? Color.orange : Color.secondary) }.buttonStyle(.plain).help("收藏仍受历史容量限制").accessibilityLabel(document.favorite ? "取消收藏" : "收藏")
            Button("编辑") { app.showEditor(document) }
            Button { Task { await app.copy(document) } } label: { Image(systemName: "doc.on.doc") }.help("复制").disabled(app.copying).accessibilityLabel("复制这张截图")
            Menu {
                Button("置顶参考") { app.pin(document) }.disabled(app.pinning)
                Button("提取文字") { app.recognize(document) }
                Button("重命名…") { app.renameDocument(document) }
                Button("保存项目…") { app.saveProject(document) }
                Button("保存…") { app.save(document) }
                Button("复制原始截图") { Task { await app.copy(document, originalOnly: true) } }
                Divider()
                Button("移除", role: .destructive) { app.removeRecent(document) }
            } label: { Image(systemName: "ellipsis") }.menuIndicator(.hidden).fixedSize().accessibilityLabel("这张截图的更多操作")
        }.controlSize(.small).padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}
