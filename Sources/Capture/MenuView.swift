import AppKit
import SwiftUI
import CaptureCore

struct MenuView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var app: AppController
    private var currentID: String { store.preferences.defaultPresetID ?? "custom" }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "viewfinder").font(.system(size: 13, weight: .medium)).foregroundStyle(CaptureTheme.accent)
                Text("Capture").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }.padding(.bottom, 2)
            Button { if app.isScrolling { app.finishScrollingCapture() } else if app.busy { app.cancelCapture() } else { app.beginCapture() } } label: {
                HStack { Image(systemName: app.isScrolling ? "checkmark" : (app.busy ? "xmark" : "viewfinder")); Text(app.isScrolling ? "结束并复制" : (app.busy ? "取消截图" : "区域截图")); Spacer(); Text(store.preferences.shortcut.display).font(.system(size: 11)) }
                    .frame(maxWidth: .infinity)
            }.buttonStyle(CaptureActionStyle(primary: true))
                .disabled((!app.busy && !app.canStartCapture) || (app.isScrolling && app.scrollFrameCount == 0))
            Button { app.showRecording() } label: {
                HStack { Image(systemName:app.recording.isBusy ? "record.circle.fill":"record.circle"); Text(app.recording.isBusy ? app.recording.stateLabel+" · "+app.recording.elapsedLabel:"录制屏幕…"); Spacer(); Text(app.recording.options.shortcut.display).font(.system(size:11)) }
            }.disabled(!app.canStartCapture && !app.recording.isBusy)
            if app.recording.isRecording { HStack { Button(app.recording.phase == .paused ? "继续录屏":"暂停录屏") { app.recording.togglePause() }; Button("停止并保存录屏") { Task { await app.recording.finish() } } } }
            if let error = store.recordingShortcutError { Text("录屏快捷键："+error).font(.system(size:11)).foregroundStyle(.orange) }
            if app.isScrolling { Button("取消长截图，不复制") { app.cancelCapture() } }
            HStack(spacing: 6) {
                Button { app.beginCapture(.window) } label: { Label("窗口", systemImage: "macwindow").frame(maxWidth: .infinity) }
                Button { app.beginCapture(.fullScreen) } label: { Label("全屏", systemImage: "display").frame(maxWidth: .infinity) }
                Button { app.beginCapture(.scrolling) } label: { Label("长截图", systemImage: "scroll").frame(maxWidth: .infinity) }
            }.disabled(!app.canStartCapture)
            HStack {
                SelectionModePicker(store: store, compact: true)
                Menu {
                    Picker("截图倒计时", selection: Binding(get: { store.preferences.captureOptions?.delay ?? 0 }, set: { value in
                        store.update { var options = $0.captureOptions ?? CaptureOptions(); options.delay = value; $0.captureOptions = options }
                    })) { Text("立即截图").tag(0); Text("3 秒").tag(3); Text("5 秒").tag(5); Text("10 秒").tag(10) }
                    Toggle("包含鼠标指针", isOn: Binding(get: { store.preferences.captureOptions?.includeCursor ?? false }, set: { value in
                        store.update { var options = $0.captureOptions ?? CaptureOptions(); options.includeCursor = value; $0.captureOptions = options }
                    }))
                    Button("重复上次区域") { app.beginCapture(.previous) }.disabled(!app.canRepeatCapture)
                } label: { Image(systemName: "ellipsis").frame(width: 12) }.menuIndicator(.hidden).fixedSize().accessibilityLabel("更多截图选项")
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("自动美化").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Toggle("自动美化", isOn: Binding(get: { store.preferences.automaticStyle }, set: { value in store.update { $0.automaticStyle = value } }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                CaptureChoice("截图默认预设", selection: Binding(get: { currentID }, set: { store.setDefaultPreset($0) }),
                    options: store.presets.map { ($0.id, $0.name) } + (currentID == "custom" ? [("custom", "自定义")] : []))
                HStack {
                    Text(store.preferences.automaticStyle ? "截图即套用 · 仅使用默认预设" : "已关闭 · 截图复制原图").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("预设库") { app.showPresets() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(CaptureTheme.accent)
                }
            }.padding(12).background(CaptureTheme.surface, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(CaptureTheme.border))
            if !store.permissionGranted {
                Button { app.showWelcome() } label: { Label("允许屏幕录制", systemImage: "lock.shield") }.foregroundStyle(.orange)
            }
            if let error = store.shortcutError ?? store.errorMessage { Text(error).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            VStack(spacing: 1) {
                menuRow("最近截图（\(app.recentDocuments.count)）", symbol: "clock.arrow.circlepath") { app.showRecent() }
                menuRow("恢复截后缩略图", symbol: "rectangle.on.rectangle", disabled: app.lastDocument == nil) { app.restoreThumbnail() }
                menuRow("打开图片或项目…", symbol: "photo.on.rectangle", disabled: app.choosingFiles || app.busy || app.recording.isBusy || app.recording.fileBusy) { app.openImage() }
                menuRow("从剪贴板打开", symbol: "clipboard") { app.importClipboard() }
                menuRow("拼接多张图片…", symbol: "rectangle.stack", disabled: app.choosingFiles || app.busy || app.recording.isBusy || app.recording.fileBusy) { app.combineImages() }
            }
            menuRow("录屏设置与最近作品…", symbol: "slider.horizontal.3") { app.showRecordingSettings() }
            Divider()
            HStack {
                Button("设置…") { app.showSettings() }.buttonStyle(.plain)
                Button("帮助") { app.showHelp() }.buttonStyle(.plain)
                Menu { Button("恢复全部交互") { app.restorePins() }; Button("关闭全部") { app.closePins() } } label: { Image(systemName: "pin") }.menuIndicator(.hidden).fixedSize().accessibilityLabel("置顶图片管理")
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(16).frame(width: 324).background(CaptureTheme.chrome).buttonStyle(CaptureActionStyle()).tint(CaptureTheme.accent)
    }
    private func menuRow(_ title: String, symbol: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).contentShape(Rectangle()) }
            .buttonStyle(.plain).font(.system(size: 12)).disabled(disabled)
    }
}

struct SelectionModePicker: View {
    @ObservedObject var store: AppStore
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !compact { Text("截图选区方式").font(.system(size: 13, weight: .medium)) }
            CaptureSegments("选区确认方式", selection: Binding(get: { (store.preferences.captureOptions ?? CaptureOptions()).allowsSelectionAdjustment }, set: { value in
                store.update { var options = $0.captureOptions ?? CaptureOptions(); options.adjustBeforeCapture = value; $0.captureOptions = options }
            }), options: [(false, "快速截图"), (true, "框选调整")])
            if !compact {
            Text((store.preferences.captureOptions ?? CaptureOptions()).allowsSelectionAdjustment
                 ? "先定格画面，拖动选区或边角调整，回车确认。"
                 : "画面定格后，框选松手即复制。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}
