import SwiftUI
import AppKit
import CaptureCore
private typealias SettingsState<Value> = SwiftUI.State<Value>

struct WelcomeView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var app: AppController
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "viewfinder").font(.system(size: 33, weight: .light)).foregroundStyle(.white)
                .frame(width: 76, height: 76).background(CaptureTheme.brand, in: RoundedRectangle(cornerRadius: 21))
            VStack(spacing: 9) {
                Text("截图，轻松分享。").font(.system(size: 25, weight: .medium))
                Text("快捷截图 · 本地录屏 · 轻松分享").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Text(store.preferences.shortcut.display).font(.system(size: 24, weight: .medium, design: .rounded))
                .padding(.horizontal, 25).padding(.vertical, 12).background(CaptureTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 10) {
                Label(store.permissionGranted ? "屏幕录制权限已就绪" : "首次截图需要屏幕录制权限", systemImage: store.permissionGranted ? "checkmark.shield" : "lock.shield")
                    .font(.system(size: 13, weight: .medium))
                Text(store.permissionGranted ? "开启自动样式后直接复制成品，关闭后复制原图。框选时按空格可选择整个窗口。" : "只在你触发截图、长截图或明确开始录屏时读取屏幕。请在系统提示中允许 Capture，再重新打开应用；若已开启仍未就绪，可在系统设置中移除旧条目并重新添加当前应用。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineSpacing(4)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(CaptureTheme.canvas, in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 10) {
                Button("先试调样式") { app.showStyleEditor() }
                if store.permissionGranted {
                    Button("截一张测试图") { app.captureTestWindow() }
                    Button("开始截图") { app.beginCapture() }.buttonStyle(CaptureActionStyle(primary: true))
                } else {
                    Button("打开系统设置") { store.openPermissionSettings() }
                    Button("允许屏幕录制") { store.requestPermission() }.buttonStyle(CaptureActionStyle(primary: true))
                }
            }.controlSize(.large)
            Text("Capture 常驻菜单栏，截图和录屏使用各自的快捷键。").font(.system(size: 11)).foregroundStyle(.tertiary)
        }.padding(36).frame(width: 530).buttonStyle(CaptureActionStyle()).tint(CaptureTheme.accent)
    }
}

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var app: AppController
    var initialSection = 0
    @SettingsState private var section = 0
    private func presentation<T>(_ key: WritableKeyPath<PresentationOptions,T>) -> Binding<T> {
        Binding(get: { (store.preferences.presentation ?? PresentationOptions())[keyPath:key] }, set: { value in
            store.update { var options = $0.presentation ?? PresentationOptions(); options[keyPath:key] = value; $0.presentation = options }
        })
    }
    private func history<T>(_ key: WritableKeyPath<HistoryOptions,T>) -> Binding<T> {
        Binding(get: { (store.preferences.localHistory ?? HistoryOptions())[keyPath:key] }, set: { value in
            store.update { var options = $0.localHistory ?? HistoryOptions(); options[keyPath:key] = value; $0.localHistory = options }
            app.library.configure(store.preferences.localHistory ?? HistoryOptions())
        })
    }
    var body: some View {
      VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("设置").font(.system(size: 19, weight: .semibold))
                Spacer()
                Text("Capture " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            CaptureSegments("设置分类", selection: $section, options: [(0,"截图"),(1,"截后浮层"),(2,"外观"),(3,"本地历史")])
        }.padding(22)
        Divider()
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
              if section == 0 {
                LoginItemSettingsView(controller: app.loginItem)
                GroupBox {
                    VStack(alignment:.leading,spacing:12) {
                        Text("截图与快捷键").font(.headline)
                        HStack {
                            ShortcutRecorder(shortcut:store.preferences.shortcut,onChange:{ app.setShortcut($0) },onRecordingChange:{ app.setShortcutRecording($0) }).frame(width:180,height:35).disabled(app.recording.isBusy)
                            Button("恢复默认") { app.setShortcut(.defaultCapture) }
                        }
                        Text(store.shortcutError ?? (app.recordingShortcut ? "正在录制，截图热键已暂停。松开完成，Esc 取消。" : "点击后按组合键；包含 ⌘、⌥ 或 ⌃，Esc 取消。"))
                            .font(.caption).foregroundStyle(store.shortcutError == nil ? .secondary : Color.orange)
                        Divider()
                        Text("录屏快捷键").font(.system(size:12,weight:.medium))
                        HStack {
                            ShortcutRecorder(shortcut:app.recording.options.shortcut,onChange:{app.setRecordingShortcut($0)},onRecordingChange:{app.setShortcutRecording($0)}).frame(width:180,height:35).disabled(app.recording.isBusy)
                            Button("恢复默认") { app.setRecordingShortcut(.defaultRecording) }
                        }
                        Text(store.recordingShortcutError ?? "直接框选录屏；录制中再次按下停止。录入时暂停两组快捷键。")
                            .font(.caption).foregroundStyle(store.recordingShortcutError == nil ? .secondary : Color.orange)
                        RecordingModePicker(controller:app.recording)
                        Button("录屏设置与最近作品…") { app.showRecordingSettings() }
                        Divider(); SelectionModePicker(store:store)
                    }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
                }
              }
              if section == 1 {
                GroupBox {
                    VStack(alignment:.leading,spacing:12) {
                        Text("截后缩略图").font(.headline)
                        Toggle("显示截后缩略图",isOn:Binding(get:{ store.preferences.showThumbnail },set:{ value in store.update { $0.showThumbnail = value } }))
                        HStack { Text("停留时间").font(.caption).frame(width: 80, alignment: .leading); CaptureChoice("停留时间",selection:presentation(\.thumbnailSeconds),options:[(3,"3 秒"),(6,"6 秒"),(10,"10 秒"),(0,"手动关闭")]) }.disabled(!store.preferences.showThumbnail)
                        HStack { Text("显示位置").font(.caption).frame(width: 80, alignment: .leading); CaptureChoice("显示位置",selection:presentation(\.corner),options:ThumbnailCorner.allCases.map { ($0,$0.label) }) }.disabled(!store.preferences.showThumbnail)
                        Text("悬停或打开菜单时暂停计时；收起后可从菜单栏恢复。").font(.caption).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
                }
              }
              if section == 3 {
                GroupBox {
                    VStack(alignment:.leading,spacing:12) {
                        Text("本地历史与隐私").font(.headline)
                        Toggle("自动保存可编辑历史到本机",isOn:history(\.enabled))
                        HStack { Text("保留时间").font(.caption).frame(width: 80, alignment: .leading); CaptureChoice("保留时间",selection:history(\.retentionDays),options:[(7,"7 天"),(30,"30 天")]) }
                        Text("默认关闭。开启后包含原图及编辑信息；最多 32 张 / 256 MB，收藏也受上限约束。关闭只停止新增，不删除已有记录。可在截图库中清空。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                        Button("打开截图库") { app.showRecent() }
                    }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
                }
              }
              if section == 2 {
                GroupBox {
                    VStack(alignment:.leading,spacing:12) {
                        Text("外观与辅助功能").font(.headline)
                        HStack { Text("界面主题").font(.caption).frame(width: 80, alignment: .leading); CaptureChoice("界面主题",selection:presentation(\.theme),options:AppTheme.allCases.map { ($0,$0.label) }) }
                        Toggle("减少动态效果",isOn:presentation(\.reduceMotion))
                        Text("尊重系统减少动态效果设置；反馈简短，不播放循环动画。").font(.caption).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
                }
              }
                HStack {
                    Label(store.permissionGranted ? "屏幕录制已允许" : "需要屏幕录制权限",systemImage:"lock.shield"); Spacer()
                    Button("刷新") { store.refreshPermission() }; Button("系统设置") { store.openPermissionSettings() }
                }.font(.caption)
                if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
                Button("快捷键、清晰度与权限指南") { app.showHelp() }.buttonStyle(.plain).foregroundStyle(CaptureTheme.accent)
            }.padding(24)
        }
      }.frame(minWidth:520,minHeight:420).background(CaptureTheme.chrome).buttonStyle(CaptureActionStyle()).tint(CaptureTheme.accent)
        .onAppear { section = initialSection }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: Shortcut
    let onChange: (Shortcut) -> String?
    let onRecordingChange: (Bool) -> Void
    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView(); view.shortcut = shortcut; view.onChange = onChange; view.onRecordingChange = onRecordingChange; return view
    }
    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.shortcut = shortcut; nsView.onChange = onChange; nsView.onRecordingChange = onRecordingChange; nsView.needsDisplay = true
    }
    static func dismantleNSView(_ nsView: RecorderView, coordinator: ()) { nsView.endRecording() }
}
