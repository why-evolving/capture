import AppKit
import SwiftUI
import CaptureCore

private typealias PresetState<Value> = SwiftUI.State<Value>

struct PresetsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var app: AppController
    let source: CGImage
    var document: CaptureDocument? = nil
    @PresetState private var search = ""
    @PresetState private var selectedID: String
    @PresetState private var preview: NSImage?
    @PresetState private var message = ""
    @PresetState private var pendingDelete: StylePreset?
    @PresetState private var showingDelete = false
    @PresetState private var pendingUpdate: StylePreset?
    @PresetState private var showingUpdate = false
    @PresetState private var previewError: String?
    init(store: AppStore, app: AppController, source: CGImage, document: CaptureDocument? = nil) {
        self.store = store; self.app = app; self.source = source; self.document = document
        _selectedID = PresetState(initialValue: store.preferences.defaultPresetID ?? StylePreset.builtIns[0].id)
    }
    private var selected: StylePreset { store.presets.first { $0.id == selectedID } ?? store.presets[0] }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("样式预设").font(.system(size: 20, weight: .semibold))
                    Text("点选预览，设为默认后用于后续截图。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("导入…") { app.importPresets() }
                Menu("导出") {
                    Button("当前预设…") { app.exportPresets([selected]) }
                    Button("全部自定义预设…") { app.exportPresets(store.preferences.customPresets) }.disabled(store.preferences.customPresets.isEmpty)
                }.fixedSize()
                Button("新建预设…") { app.showStyleEditor(style: selected.style) }.help("从选中样式开始调整，然后点「存为预设」")
            }.padding(22)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    TextField("搜索预设", text: $search)
                        .textFieldStyle(CaptureFieldStyle())
                        .accessibilityIdentifier("preset-search")
                        .padding(14)
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                if !search.isEmpty && !store.presets.contains(where: { $0.name.localizedCaseInsensitiveContains(search) }) {
                                    Text("没有匹配的预设").font(.caption).foregroundStyle(.secondary)
                                    Button("清除搜索") { search = "" }
                                }
                                if !store.preferences.customPresets.isEmpty { section("我的预设", presets: store.preferences.customPresets) }
                                section("内置预设", presets: StylePreset.builtIns)
                            }.padding(14)
                        }.onAppear { proxy.scrollTo(selectedID, anchor: .top) }
                    }
                }.frame(width: 250)
                Divider()
                VStack(spacing: 14) {
                    HStack {
                        Text(selected.name).font(.system(size: 15, weight: .semibold))
                        if selected.id == store.preferences.defaultPresetID { Label("截图默认", systemImage: "star.fill").font(.system(size: 10)).foregroundStyle(CaptureTheme.accent) }
                        Spacer()
                        Menu("管理") {
                            Button("复制为新预设…") { namePreset(selected, duplicate: true) }
                            if !selected.isBuiltIn {
                                Button("重命名…") { namePreset(selected, duplicate: false) }
                                if document != nil { Button("用当前图片的样式更新…") { pendingUpdate = selected; showingUpdate = true } }
                                Button("删除…", role: .destructive) { pendingDelete = selected; showingDelete = true }
                            }
                        }.fixedSize().controlSize(.small)
                    }
                    ZStack {
                        if let preview { Image(nsImage: preview).resizable().scaledToFit() }
                        else if let previewError { Label(previewError, systemImage: "exclamationmark.triangle").font(.system(size: 12)).padding() }
                        else { ProgressView("生成预览…") }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background { if selected.style.background == .transparent { Checkerboard() } else { CaptureTheme.canvas } }.clipShape(RoundedRectangle(cornerRadius: 9))
                    Text(document == nil ? "使用示例图预览；不需要屏幕录制权限。" : "使用当前截图内容预览；选择预设不会改动当前图片。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if let document {
                            Button("应用到当前图片") { document.setStyle(selected.style); message = "已应用到当前图片，截图默认预设未改变。" }
                        } else {
                            Button("编辑此样式…") { app.showStyleEditor(style: selected.style) }
                        }
                        Spacer(minLength: 0)
                        Button(selected.id == store.preferences.defaultPresetID ? "已是截图默认" : "设为截图默认") {
                            store.setDefaultPreset(selected.id); message = "已设为默认：\(selected.name)"
                        }.buttonStyle(CaptureActionStyle(primary: true)).disabled(selected.id == store.preferences.defaultPresetID)
                    }.controlSize(.small)
                }.padding(22)
            }
            Divider()
            HStack(spacing: 12) {
                Toggle("截图时自动套用默认预设", isOn: Binding(get: { store.preferences.automaticStyle }, set: { value in store.update { $0.automaticStyle = value } }))
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                Spacer()
                Text(store.errorMessage ?? (message.isEmpty ? (store.preferences.automaticStyle ? "默认：\(store.defaultName)" : "已关闭，截图复制原图；预设仍会保留。") : message))
                    .font(.system(size: 10)).foregroundStyle(store.errorMessage == nil ? .secondary : Color.orange).lineLimit(2)
            }.padding(18)
        }.frame(minWidth: 820, minHeight: 570).background(CaptureTheme.chrome).buttonStyle(CaptureActionStyle()).tint(CaptureTheme.accent)
        .task(id: selected.style) {
            preview = nil; previewError = nil
            let style = selected.style
            do {
                let rendered = try await Task.detached(priority: .userInitiated) { try StyleCompositor.render(source, style: style, previewLimit: 2200) }.value
                guard !Task.isCancelled else { return }
                preview = NSImage(cgImage: rendered, size: CGSize(width: rendered.width, height: rendered.height))
            } catch { if !Task.isCancelled { previewError = error.localizedDescription; message = error.localizedDescription } }
        }
        .onChange(of: store.presets.map(\.id)) { _, ids in if !ids.contains(selectedID) { selectedID = store.preferences.defaultPresetID ?? StylePreset.builtIns[0].id } }
        .confirmationDialog("删除预设？", isPresented: $showingDelete, titleVisibility: .visible, presenting: pendingDelete) { preset in
            Button("删除「\(preset.name)」", role: .destructive) { store.deletePreset(preset.id); pendingDelete = nil; message = "已删除「\(preset.name)」" }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { _ in Text("删除默认预设后，将使用内置「暮光」。当前图片不会改变。") }
        .confirmationDialog("更新预设？", isPresented: $showingUpdate, titleVisibility: .visible, presenting: pendingUpdate) { preset in
            Button("更新「\(preset.name)」") { if let document { store.updatePreset(preset.id, style: document.style); message = "已更新「\(preset.name)」" }; pendingUpdate = nil }
            Button("取消", role: .cancel) { pendingUpdate = nil }
        } message: { preset in Text("将替换「\(preset.name)」保存的外观。若它是截图默认，后续截图也会使用新外观。") }
    }
    @ViewBuilder
    private func section(_ title: String, presets: [StylePreset]) -> some View {
        Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.top, 5)
        ForEach(presets.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { preset in
            Button { selectedID = preset.id; message = "" } label: {
                HStack(spacing: 9) {
                    PresetThumbnail(source: source, style: preset.style).frame(width: 68, height: 45).clipShape(RoundedRectangle(cornerRadius: 5))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(preset.name).font(.system(size: 11, weight: .medium)).lineLimit(2)
                        if preset.id == store.preferences.defaultPresetID { Label("默认", systemImage: "star.fill").font(.system(size: 9)).foregroundStyle(CaptureTheme.accent) }
                    }
                    Spacer(minLength: 0)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(selectedID == preset.id ? CaptureTheme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).id(preset.id).contextMenu {
                Button("设为截图默认") { store.setDefaultPreset(preset.id) }
                Button("复制为新预设…") { namePreset(preset, duplicate: true) }
                if !preset.isBuiltIn {
                    Button("重命名…") { namePreset(preset, duplicate: false) }
                    if document != nil { Button("用当前图片的样式更新…") { pendingUpdate = preset; showingUpdate = true } }
                    Divider()
                    Button("删除…", role: .destructive) { pendingDelete = preset; showingDelete = true }
                }
            }
        }
    }
    private func namePreset(_ preset: StylePreset, duplicate: Bool) {
        let alert = NSAlert(); alert.messageText = duplicate ? "复制预设" : "重命名预设"
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        var suggestion = preset.name
        if duplicate {
            let base = String(preset.name.prefix(30)) + " 副本"
            suggestion = base; var number = 2
            while store.presets.contains(where: { $0.name.localizedCaseInsensitiveCompare(suggestion) == .orderedSame }) { suggestion = base + " \(number)"; number += 1 }
        }
        let field = CapturePanelField(input: suggestion); field.frame = CGRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field; alert.window.initialFirstResponder = field
        while alert.runModal() == .alertFirstButtonReturn {
            if duplicate {
                if let id = store.savePreset(name: field.stringValue, style: preset.style) { selectedID = id; return }
            } else {
                store.renamePreset(preset.id, name: field.stringValue)
                if store.errorMessage == nil { return }
            }
            alert.alertStyle = .warning; alert.informativeText = store.errorMessage ?? "请检查预设名称。"
        }
    }
}

private struct PresetThumbnail: View {
    let source: CGImage
    let style: CaptureStyle
    @PresetState private var image: NSImage?
    var body: some View {
        ZStack {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Color.gray.opacity(0.08) }
        }.task(id: style) {
            if let rendered = try? await Task.detached(priority: .utility, operation: { try StyleCompositor.render(source, style: style, previewLimit: 200) }).value, !Task.isCancelled {
                image = NSImage(cgImage: rendered, size: CGSize(width: rendered.width, height: rendered.height))
            }
        }
    }
}
