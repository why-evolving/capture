import SwiftUI
import AppKit
import CaptureCore
import UniformTypeIdentifiers

// Use the public property-wrapper type explicitly. The macOS 27 SDK also exposes
// a same-named macro whose plugin is shipped with Xcode, not Command Line Tools.
private typealias LocalViewState<Value> = SwiftUI.State<Value>

enum EditorTab: String, CaseIterable {
    case background = "背景", markup = "标注", layout = "布局", effects = "效果", export = "导出"
    var symbol: String {
        switch self { case .background: return "paintpalette"; case .markup: return "pencil.tip.crop.circle"; case .layout: return "rectangle.inset.filled"; case .effects: return "slider.horizontal.3"; case .export: return "square.and.arrow.up" }
    }
}

struct EditorView: View {
    @ObservedObject var document: CaptureDocument
    @ObservedObject var store: AppStore
    @ObservedObject var app: AppController
    var initialTab: EditorTab = .background
    // Optional binding lets the native regression fixture observe real button actions.
    var tabSelection: Binding<EditorTab>? = nil
    @LocalViewState private var localTab: EditorTab = .background
    private var tab: EditorTab {
        get { tabSelection?.wrappedValue ?? localTab }
        nonmutating set { if let tabSelection { tabSelection.wrappedValue = newValue } else { localTab = newValue } }
    }
    @LocalViewState private var markupTool: MarkupTool = .annotation(.arrow)
    @LocalViewState private var annotationColor = CaptureCore.RGBColor(hex: "FF453A")
    @LocalViewState private var annotationWidth = 6.0
    @LocalViewState private var annotationText = "添加文字"
    @LocalViewState private var zoom = 0.0
    private var selectedAnnotation: UUID? {
        get { document.selectedAnnotationID }
        nonmutating set { document.selectedAnnotationID = newValue }
    }
    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            HStack(spacing: 0) {
                toolRail
                Divider()
                canvas
                Divider()
                inspector.frame(width: 296)
            }
        }
        .background(CaptureTheme.chrome)
        .buttonStyle(CaptureActionStyle()).tint(CaptureTheme.accent)
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 800, minHeight: 580)
        .onAppear { tab = initialTab }
        .onChange(of: selectedAnnotation) { _, id in
            if let item = document.edits.annotations.first(where: { $0.id == id }) {
                annotationColor = item.color; annotationWidth = item.lineWidth
                if item.kind == .text { annotationText = item.text }
            }
        }
        .onChange(of: document.edits) { _, _ in
            if let item = document.edits.annotations.first(where: { $0.id == selectedAnnotation }) {
                annotationColor = item.color; annotationWidth = item.lineWidth
                if item.kind == .text { annotationText = item.text }
            }
        }
        .sheet(isPresented: $document.showingRecognition) { RecognitionView(document: document, pasteboard: app.clipboard) }
        .onDrop(of: [UTType.fileURL.identifier, UTType.png.identifier, UTType.tiff.identifier], isTargeted: nil) { app.importDroppedImage($0) }
    }
    private var titleBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo").font(.system(size: 13)).foregroundStyle(.secondary)
            Text(document.isSample ? "样式预览" : document.filename).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            if document.isSample { Text("示例图片").font(.system(size: 11)).foregroundStyle(.secondary) }
            Spacer()
            ShareImageButton(document: document).frame(width: 30, height: 24)
            Button { document.showingRecognition = true } label: { Image(systemName: "text.viewfinder") }.help("提取文字与二维码").accessibilityLabel("提取文字与二维码")
            Button { app.pin(document) } label: { Image(systemName: "pin") }.help("置顶参考图").accessibilityLabel("置顶参考图").disabled(app.pinning)
            Button { app.promptSavePreset(document) } label: { Label("存为预设", systemImage: "square.stack") }.controlSize(.small)
            Button { Task { await app.copy(document) } } label: {
                Label(app.copying ? "复制中…" : "复制", systemImage: "doc.on.doc")
                    .padding(.horizontal, 3)
            }.buttonStyle(CaptureActionStyle(primary: true)).disabled(app.copying)
            Menu {
                Button("保存 PNG…") { document.outputFormat = .png; app.save(document) }
                Button("保存 JPEG…") { document.outputFormat = .jpeg; app.save(document) }
                Divider()
                Button("复制原始截图（不含编辑）") { Task { await app.copy(document, originalOnly: true) } }
                Button("保存原始截图（不含编辑）…") { app.save(document, originalOnly: true) }
                Button("保存可编辑项目…") { app.saveProject(document) }
                Button("更多导出设置") { tab = .export }
            } label: { Label(app.saving ? "保存中…" : "导出", systemImage: "square.and.arrow.down") }.fixedSize().disabled(app.saving)
        }
        .padding(.leading, 80).padding(.trailing, 18).frame(height: 62)
    }
    private var toolRail: some View {
        VStack(spacing: 10) {
            ForEach(EditorTab.allCases, id: \.self) { item in
                Button { tab = item } label: {
                    VStack(spacing: 6) { Image(systemName: item.symbol).font(.system(size: 17)); Text(item.rawValue).font(.system(size: 10)) }
                        .frame(width: 44, height: 52)
                        // Plain buttons otherwise ignore the transparent gaps in this label.
                        .contentShape(Rectangle())
                        .foregroundStyle(tab == item ? CaptureTheme.accent : .secondary)
                        .background(tab == item ? CaptureTheme.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 10))

                }.buttonStyle(.plain).accessibilityLabel(item.rawValue)
            }
            Spacer()
            Button { document.reset() } label: {
                VStack(spacing: 5) { Image(systemName: "arrow.counterclockwise"); Text("还原样式").font(.system(size: 10)) }.frame(width: 44, height: 48)
            }.buttonStyle(.plain).foregroundStyle(.secondary).help("还原美化设置，可以撤销")
        }.padding(.horizontal, 6).padding(.vertical, 14).frame(width: 57).background(CaptureTheme.chrome)
    }
    private var canvas: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { document.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!document.canUndo).help("撤销 ⌘Z").accessibilityLabel("撤销")
                Button { document.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!document.canRedo).help("重做 ⇧⌘Z").accessibilityLabel("重做")
                Divider().frame(height: 15)
                Text(document.rendering ? "正在渲染…" : (tab == .markup ? "编辑截图内容" : "成品预览")).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button { document.showOriginal.toggle() } label: {
                    Label(document.showOriginal ? "返回编辑" : "查看原图", systemImage: "rectangle.split.2x1")
                        .font(.system(size: 11)).foregroundStyle(document.showOriginal ? CaptureTheme.accent : .secondary)
                }.help("对比原始截图；复制与导出仍保留当前编辑")
            }.buttonStyle(.plain).padding(.horizontal, 18).frame(height: 48)
            if document.showOriginal {
                Label("正在对比原图；复制与导出仍保留编辑和遮挡。", systemImage: "eye")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 8)
            }
            ZStack {
                if tab == .markup && !document.showOriginal {
                    AnnotationCanvas(document: document, tool: markupTool, color: annotationColor, lineWidth: annotationWidth, text: annotationText, selected: $document.selectedAnnotationID)
                } else if zoom > 0 {
                    PixelPreview(document: document, zoom: zoom)
                } else if document.showOriginal {
                    Image(nsImage: document.originalImage()).resizable().interpolation(.high).scaledToFit().padding(30)
                } else if let image = document.preview {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                        .background { if document.useStyle && document.style.background == .transparent { Checkerboard() } }
                        .padding(30).onDrag { document.itemProvider() }
                } else { ProgressView("生成预览…").controlSize(.small) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let message = document.message {
                HStack(spacing: 8) {
                    Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 5)
                    Button { document.message = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain)
                }.padding(11).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9)).padding(.horizontal, 16).padding(.bottom, 10)
            }
            Divider()
            HStack {
                CaptureChoice("预览缩放", selection: $zoom, options: [(0.0,"适应"),(0.5,"50%"),(1.0,"100%"),(2.0,"200%"),(4.0,"400%")])
                    .frame(width: 88).disabled(tab == .markup).help("100% 对应真实屏幕像素；仅改变预览")
                Label(document.dimensionLabel + " · 成品", systemImage: "photo")
                Spacer()
                if tab == .markup { Button("查看成品") { tab = .background }.buttonStyle(.plain).foregroundStyle(CaptureTheme.accent) }
                else { Toggle("美化", isOn: Binding(get: { document.useStyle }, set: { document.change(style: document.style, enabled: $0) })).toggleStyle(.switch).controlSize(.mini) }
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 43)
        }.background(CaptureTheme.canvas)
    }
    private var inspector: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Text(tab.rawValue).font(.system(size: 16, weight: .semibold))
                        Spacer()
                        Text(tab == .background ? activeName : subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(.bottom, 1)
                    switch tab {
                    case .background: backgroundPanel
                    case .markup: markupPanel
                    case .layout: layoutPanel
                    case .effects: effectsPanel
                    case .export: exportPanel
                    }
                }.frame(width: 256, alignment: .leading).padding(20)
            }
            Divider()
            Toggle(isOn: Binding(get: { store.preferences.automaticStyle }, set: { enabled in
                store.update { $0.automaticStyle = enabled }
            })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("截图时自动套用样式").font(.system(size: 10))
                    Text(store.preferences.automaticStyle ? "默认预设：\(store.defaultName)" : "下次截图直接复制原图")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.toggleStyle(.switch).controlSize(.mini).padding(.horizontal, 16).padding(.vertical, 12)
        }.background(CaptureTheme.surface)
    }
    private var activeName: String { store.presets.first(where: { $0.style == document.style })?.name ?? "自定义" }
    private var subtitle: String {
        switch tab { case .background: return ""; case .markup: return "可撤销编辑"; case .layout: return "画布与间距"; case .effects: return "细节与层次"; case .export: return "输出设置" }
    }
    private var backgroundPanel: some View {
        Group {
            VStack(alignment: .leading, spacing: 12) {
                smallLabel("常用预设")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 12) {
                    ForEach(StylePreset.builtIns.prefix(6)) { preset in
                        Button { document.setStyle(preset.style) } label: {
                            VStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 9)
                                    .fill(LinearGradient(colors: [preset.style.firstColor.color, preset.style.secondColor.color], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(height: 48)
                                    .overlay {
                                        VStack(spacing: 0) {
                                            if preset.style.windowFrame {
                                                HStack(spacing: 1.5) { ForEach([Color.red, .yellow, .green], id: \.self) { $0.frame(width: 2, height: 2).clipShape(Circle()) }; Spacer(minLength: 0) }
                                                    .padding(.leading, 3).frame(height: 6).background(preset.style.windowAppearance == .dark ? Color(white: 0.2) : Color(white: 0.9))
                                            }
                                            Color(red: 0.99, green: 0.98, blue: 0.97)
                                        }.frame(width: 32, height: 20).clipShape(RoundedRectangle(cornerRadius: 3)).shadow(color: .black.opacity(0.16), radius: 3, y: 3)
                                    }
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(CaptureTheme.accent, lineWidth: document.style == preset.style ? 2 : 0).padding(-3))
                                Text(preset.name).font(.system(size: 10)).foregroundStyle(document.style == preset.style ? CaptureTheme.accent : .secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                }
                Menu("全部预设（\(store.presets.count)）") {
                    if !store.preferences.customPresets.isEmpty {
                        Section("我的预设（\(store.preferences.customPresets.count)）") {
                            ForEach(store.preferences.customPresets) { preset in presetMenuItem(preset) }
                        }
                    }
                    Section("内置预设（\(StylePreset.builtIns.count)）") {
                        ForEach(StylePreset.builtIns) { preset in presetMenuItem(preset) }
                    }
                    Divider()
                    Button("预览与管理全部预设…") { app.showPresets(document: document) }
                }.font(.system(size: 11)).frame(maxWidth: .infinity)
                Text("仅应用当前图片，截图默认不变。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            }
            CaptureSegments("背景类型", selection: styleBinding(\.background), options: BackgroundKind.allCases.map { ($0, $0.label) })
            if document.style.background != .transparent {
                VStack(alignment: .leading, spacing: 10) {
                    smallLabel("颜色")
                    HStack {
                        colorField(\.firstColor)
                        if (document.style.background == .gradient || document.style.background == .aurora) {
                            Button {
                                var style = document.style
                                swap(&style.firstColor, &style.secondColor)
                                document.setStyle(style)
                            } label: { Image(systemName: "arrow.left.arrow.right").font(.system(size: 11)) }.buttonStyle(.plain).foregroundStyle(.secondary)
                            colorField(\.secondColor)
                        }
                    }
                }
                if (document.style.background == .gradient || document.style.background == .aurora) { parameter("渐变角度", \.angle, range: 0...360, step: 5, unit: "°") }
            }
            Button { document.suggestBackground() } label: { Label("从截图生成配色", systemImage: "wand.and.stars").frame(maxWidth: .infinity) }.controlSize(.small)
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Toggle("细腻颗粒", isOn: styleBinding(\.grain)).toggleStyle(.switch).controlSize(.mini).font(.system(size: 12))
                    .disabled(document.style.background == .transparent)
                Text("为渐变增加轻微质感").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
    private var layoutPanel: some View {
        Group {
            VStack(alignment: .leading, spacing: 10) {
                smallLabel("画幅比例")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(CanvasRatio.allCases, id: \.self) { ratio in
                        Button { var style = document.style; style.ratio = ratio; document.setStyle(style) } label: {
                            HStack(spacing: 7) { Image(systemName: ratio == .square ? "square" : "rectangle"); Text(ratio.label) }
                                .font(.system(size: 11)).frame(maxWidth: .infinity).padding(.vertical, 8)
                                .foregroundStyle(document.style.ratio == ratio ? CaptureTheme.accent : .secondary)
                                .background(document.style.ratio == ratio ? CaptureTheme.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(document.style.ratio == ratio ? CaptureTheme.accent : .secondary.opacity(0.22)))
                        }.buttonStyle(.plain)
                    }
                }
            }
            parameter("四周留白", \.padding, range: 0...240, step: 4, unit: " px")
            parameter("截图大小", \.imageScale, range: 60...100, step: 2, unit: "%")
            VStack(alignment: .leading, spacing: 10) {
                smallLabel("垂直位置")
                CaptureSegments("垂直位置", selection: styleBinding(\.position), options: VerticalPosition.allCases.map { ($0, $0.label) })
            }
            Text("固定画幅保留截图原比例，额外空间由背景填充。").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
        }
    }
    private var markupPanel: some View {
        Group {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                markupButton("选择", symbol: "cursorarrow", tool: .select)
                markupButton("裁剪", symbol: "crop", tool: .crop)
                ForEach(AnnotationKind.allCases, id: \.self) { kind in markupButton(kind.label, symbol: kind.symbol, tool: .annotation(kind)) }
            }
            Text(markupHint).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
            if let kind = selectedKind, kind != .redact && kind != .pixelate {
                HStack {
                    smallLabel("标注颜色")
                    Spacer()
                    CaptureColorWell("标注颜色", selection: Binding(get: { annotationColor.color }, set: { value in
                        annotationColor = CaptureCore.RGBColor(value)
                        editSelected { $0.color = annotationColor }
                    }))
                }
                HStack { smallLabel("粗细与字号"); Spacer(); Text("\(Int(annotationWidth))").font(.system(size: 11)).monospacedDigit() }
                CaptureSlider(value: Binding(get: { annotationWidth }, set: { value in annotationWidth = value; editSelected { $0.lineWidth = value } }), in: 2...14, onEditingChanged: { document.groupChanges($0) }).controlSize(.small)
                if kind == .text {
                    TextField("文字内容", text: Binding(get: { annotationText }, set: { value in
                        annotationText = String(value.prefix(2000)); editSelected { if $0.kind == .text { $0.text = annotationText } }
                    }), axis: .vertical).textFieldStyle(CaptureFieldStyle()).lineLimit(2...5)
                }
            }
            if let id = selectedAnnotation {
                Button(role: .destructive) { document.deleteAnnotation(id); selectedAnnotation = nil } label: {
                    Label("删除选中标注", systemImage: "trash").frame(maxWidth: .infinity)
                }
            }
            Divider()
            HStack {
                Button { document.rotate(); selectedAnnotation = nil } label: { Label("旋转", systemImage: "rotate.right") }
                Button { document.flip(); selectedAnnotation = nil } label: { Label("镜像", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
            }.controlSize(.small)
            Button("重置内容编辑") { document.removeEdits(); selectedAnnotation = nil }.disabled(document.edits.isEmpty)
            Text("原始截图始终保留；⌘Z 撤销。标注模式显示截图内容，点击「查看成品」返回美化预览。").font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(4)
            Divider()
            Button { document.showingRecognition = true } label: { Label("提取文字 / 智能遮挡", systemImage: "text.viewfinder").frame(maxWidth: .infinity) }
        }
    }
    private var markupHint: String {
        switch markupTool {
        case .select: return "点击标注后拖动调整位置，也可删除选中标注。"
        case .crop: return "拖出要保留的范围，松手完成裁剪；⌘Z 可撤销。"
        case .annotation(.text): return "先输入文字，再点击或拖动放置文字框。"
        case .annotation(.counter): return "点击放置序号，编号会自动递增。"
        case .annotation(.redact): return "拖动遮挡敏感信息，导出后为实色覆盖。"
        case .annotation(.pixelate): return "拖动添加马赛克。敏感内容建议使用实色遮挡。"
        default: return "在截图上拖动添加标注；原始图片不会被修改。"
        }
    }
    private var selectedKind: AnnotationKind? {
        if let item = document.edits.annotations.first(where: { $0.id == selectedAnnotation }) { return item.kind }
        if case .annotation(let kind) = markupTool { return kind }
        return nil
    }
    private func markupButton(_ title: String, symbol: String, tool: MarkupTool) -> some View {
        Button { markupTool = tool; selectedAnnotation = nil; document.showOriginal = false } label: {
            VStack(spacing: 5) {
                if tool == .annotation(.text) { Text("T").font(.system(size: 17, weight: .medium, design: .serif)) }
                else { Image(systemName: symbol).font(.system(size: 15)) }
                Text(title).font(.system(size: 10))
            }
                .frame(maxWidth: .infinity).frame(height: 49)
                .foregroundStyle(markupTool == tool ? CaptureTheme.accent : .secondary)
                .background(markupTool == tool ? CaptureTheme.accent.opacity(0.08) : CaptureTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(markupTool == tool ? CaptureTheme.accent.opacity(0.6) : CaptureTheme.border))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(title)
    }
    private func editSelected(_ change: (inout Annotation) -> Void) {
        guard let id = selectedAnnotation, let index = document.edits.annotations.firstIndex(where: { $0.id == id }) else { return }
        var edits = document.edits; change(&edits.annotations[index]); document.setEdits(edits)
    }
    private var effectsPanel: some View {
        Group {
            parameter("截图圆角", \.radius, range: 0...48, step: 1, unit: " px")
            parameter("阴影强度", \.shadow, range: 0...100, step: 1, unit: "%")
            parameter("阴影柔和度", \.softness, range: 0...100, step: 1, unit: "%")
            Divider()
            effectToggle("细描边", detail: "让截图与浅色背景自然分离", key: \.border)
            effectToggle("macOS 窗口", detail: "交通灯按钮、立体顶栏与细边框", key: \.windowFrame)
            if document.style.windowFrame {
                CaptureSegments("窗口配色", selection: styleBinding(\.windowAppearance), options: WindowAppearance.allCases.map { ($0, $0.label) })
                VStack(alignment: .leading, spacing: 8) {
                    smallLabel("窗口标题（可选）")
                    TextField("不显示标题", text: Binding(get: { document.style.windowTitle }, set: { value in
                        var style = document.style; style.windowTitle = String(value.prefix(120)); document.setStyle(style)
                    })).textFieldStyle(CaptureFieldStyle())
                }
                Text("已截到真实窗口顶栏时，可关闭装饰以避免重复。").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
    private func presetMenuItem(_ preset: StylePreset) -> some View {
        Button { document.setStyle(preset.style) } label: {
            let name = preset.name + (preset.id == store.preferences.defaultPresetID ? " · 截图默认" : "")
            if document.style == preset.style { Label(name, systemImage: "checkmark") }
            else { Text(name) }
        }
    }
    private var exportPanel: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                Label("稍后继续编辑", systemImage: "doc.richtext").font(.system(size: 12, weight: .medium))
                Text("项目包含未遮挡的原图。\n对外分享请用 PNG / JPEG。").font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: 232, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                Button("保存可编辑项目…") { app.saveProject(document) }.disabled(app.saving)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(CaptureTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 8) { smallLabel("文件名称"); TextField("截图名称", text: Binding(get: { document.filename }, set: { document.filename = String($0.prefix(200)) })).textFieldStyle(CaptureFieldStyle()) }
            VStack(alignment: .leading, spacing: 8) {
                smallLabel("保存格式")
                CaptureSegments("图片格式", selection: $document.outputFormat, options: ImageFormat.allCases.map { ($0, $0.rawValue) })
                Text(document.outputFormat == .png ? "无损画质，支持透明背景。" : "高质量压缩，透明区域以白色填充。").font(.system(size: 10)).foregroundStyle(.secondary)
                Text("剪贴板始终使用无损图片格式。").font(.system(size: 10)).foregroundStyle(.secondary)
                if document.outputFormat == .jpeg {
                    HStack { smallLabel("JPEG 画质"); Spacer(); Text("\(Int(document.jpegQuality * 100))%").font(.system(size: 11)) }
                    CaptureSlider(value: $document.jpegQuality, in: 0.4...1).controlSize(.small)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                smallLabel("输出倍率")
                CaptureChoice("输出倍率", selection: $document.outputScale, options: [(0.5,"0.5× · 缩小"),(1.0,"1× · 原始像素"),(2.0,"2× · 放大"),(3.0,"3× · 放大")])
                Text("复制与保存均使用此倍率。放大不会增加细节。").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(document.exportLabel).font(.system(size: 16, weight: .medium)).monospacedDigit()
                Text(document.outputFormat.rawValue).font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(CaptureTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
            Button { app.save(document) } label: { Label("保存到文件…", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity).padding(.vertical, 4) }
                .buttonStyle(CaptureActionStyle(primary: true)).disabled(app.saving)
        }
    }
    private func smallLabel(_ value: String) -> some View { Text(value).font(.system(size: 11)).foregroundStyle(.secondary) }
    private func styleBinding<T>(_ key: WritableKeyPath<CaptureStyle, T>) -> Binding<T> {
        Binding(get: { document.style[keyPath: key] }, set: { value in var style = document.style; style[keyPath: key] = value; document.setStyle(style) })
    }
    private func parameter(_ title: String, _ key: WritableKeyPath<CaptureStyle, Double>, range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text(title).font(.system(size:12)); Spacer()
                TextField(title,value:Binding(get:{ document.style[keyPath:key] },set:{ value in
                    guard value.isFinite else { return }; var style = document.style
                    style[keyPath:key] = min(range.upperBound,max(range.lowerBound,(value / step).rounded() * step)); document.setStyle(style)
                }),format:.number.precision(.fractionLength(0))).textFieldStyle(CaptureFieldStyle()).frame(width:52).multilineTextAlignment(.trailing).accessibilityLabel(title)
                Text(unit).font(.system(size:10)).foregroundStyle(.secondary)
            }
            CaptureSlider(value: Binding(get: { document.style[keyPath: key] }, set: { value in
                var style = document.style
                style[keyPath: key] = min(range.upperBound, max(range.lowerBound, (value / step).rounded() * step))
                document.setStyle(style)
            }), in: range, onEditingChanged: { document.groupChanges($0) }).controlSize(.small)
        }
    }
    private func colorField(_ key: WritableKeyPath<CaptureStyle, CaptureCore.RGBColor>) -> some View {
        HStack(spacing: 5) {
            CaptureColorWell("颜色", selection: Binding(get: { document.style[keyPath: key].color }, set: { value in
                var style = document.style; style[keyPath: key] = CaptureCore.RGBColor(value); document.setStyle(style)
            })).fixedSize()
            Text(document.style[keyPath: key].hex).font(.system(size: 11)).monospaced().foregroundStyle(.secondary)
        }.padding(6).frame(maxWidth: .infinity).background(CaptureTheme.chrome, in: RoundedRectangle(cornerRadius: 7))
    }
    private func effectToggle(_ title: String, detail: String, key: WritableKeyPath<CaptureStyle, Bool>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle(title, isOn: styleBinding(key)).toggleStyle(.switch).controlSize(.mini).font(.system(size: 12))
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell = 10.0
            for y in stride(from: 0.0, to: size.height, by: cell) {
                for x in stride(from: 0.0, to: size.width, by: cell) {
                    context.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)),
                                 with: .color((Int(x / cell) + Int(y / cell)) % 2 == 0 ? .gray.opacity(0.13) : .gray.opacity(0.04)))
                }
            }
        }
    }
}
