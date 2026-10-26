import AVKit
import AppKit
import CaptureCore
import SwiftUI

struct RecordingSetupView: View {
  @ObservedObject var controller: RecordingController
  private func option<T>(_ key: WritableKeyPath<RecordingOptions, T>) -> Binding<T> {
    Binding(
      get: { controller.options[keyPath: key] }, set: { controller.options[keyPath: key] = $0 })
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "record.circle").font(.system(size: 26, weight: .light)).foregroundStyle(
          CaptureTheme.accent)
        VStack(alignment: .leading, spacing: 5) {
          Text("录制屏幕").font(.system(size: 22, weight: .semibold))
          Text("录下操作，也录下你的讲解。").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        Spacer()
      }.padding(24)
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          RecordingModePicker(controller: controller)
          HStack(spacing: 10) {
            ForEach(RecordingScope.allCases, id: \.self) { scope in
              Button {
                controller.chooseScope(scope)
              } label: {
                VStack(alignment: .leading, spacing: 7) {
                  Label(scope.label, systemImage: scope.symbol).font(
                    .system(size: 13, weight: .semibold))
                  Text(scope == .area ? "只录需要的部分" : scope == .window ? "跟随一个窗口" : "记录整个屏幕").font(
                    .system(size: 10)
                  ).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(
                  controller.options.scope == scope
                    ? CaptureTheme.accent.opacity(0.06) : CaptureTheme.surface,
                  in: RoundedRectangle(cornerRadius: 11)
                ).overlay(
                  RoundedRectangle(cornerRadius: 11).stroke(
                    controller.options.scope == scope ? CaptureTheme.accent : CaptureTheme.border,
                    lineWidth: 1))
              }.buttonStyle(.plain).accessibilityLabel("录制" + scope.label).accessibilityValue(
                controller.options.scope == scope ? "已选中" : "未选中")
            }
          }
          HStack {
            VStack(alignment: .leading, spacing: 5) {
              Text(controller.targetLabel).font(.system(size: 12, weight: .medium))
              Text("录制实时画面，不套用截图美化预设").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if controller.options.scope != .display {
              Button("框选录屏") { controller.beginQuick() }
            }
          }.padding(14).background(CaptureTheme.surface, in: RoundedRectangle(cornerRadius: 11))
          VStack(spacing: 14) {
            audioRow(
              "电脑声音", detail: "应用播放的声音，可能包含其他应用", symbol: "speaker.wave.2",
              enabled: option(\.computerAudio), volume: option(\.computerVolume))
            Divider()
            audioRow(
              "麦克风", detail: "添加旁白，开始录制时才会收音", symbol: "mic", enabled: option(\.microphone),
              volume: option(\.microphoneVolume))
            HStack(spacing: 8) {
              CaptureChoice(
                "麦克风设备",
                selection: Binding(
                  get: { controller.options.microphoneID ?? "" },
                  set: { controller.options.microphoneID = $0.isEmpty ? nil : $0 }),
                options: [("", "系统默认麦克风")]
                  + controller.devices.map { ($0.uniqueID, $0.localizedName) })
              Button {
                controller.refreshDevices()
              } label: {
                Image(systemName: "arrow.clockwise").frame(width: 12)
              }.help("刷新麦克风设备").accessibilityLabel("刷新麦克风设备")
            }.disabled(!controller.options.microphone)
          }.padding(16).background(CaptureTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(CaptureTheme.border))
          HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
              Text("画质上限").font(.caption).foregroundStyle(.secondary)
              CaptureChoice(
                "录屏画质", selection: option(\.quality),
                options: RecordingQuality.allCases.map { ($0, $0.label) })
            }
            VStack(alignment: .leading, spacing: 7) {
              Text("帧率").font(.caption).foregroundStyle(.secondary)
              CaptureChoice(
                "录屏帧率", selection: option(\.framesPerSecond),
                options: [(30, "30 fps"), (60, "60 fps")])
            }.frame(width: 120)
          }
          HStack {
            Toggle("包含鼠标指针", isOn: option(\.includeCursor)).font(.system(size: 12))
            Spacer()
            Text("倒计时").font(.system(size: 11)).foregroundStyle(.secondary)
            CaptureChoice(
              "录屏倒计时", selection: option(\.countdown), options: [(0, "立即"), (3, "3 秒"), (5, "5 秒")]
            ).frame(width: 100)
          }
          Text("MP4 · H.264 · 最长60分钟 · 全程保存在本机").font(.system(size: 10)).foregroundStyle(.tertiary)
          if !controller.recent.isEmpty {
            Divider()
            Text("最近录屏").font(.system(size: 12, weight: .semibold))
            ForEach(controller.recent.prefix(20)) { entry in
              HStack {
                Image(systemName: entry.completed ? "play.rectangle" : "arrow.clockwise.circle")
                  .foregroundStyle(entry.completed ? CaptureTheme.accent : Color.orange)
                VStack(alignment: .leading, spacing: 4) {
                  Text(entry.title).font(.system(size: 11))
                  Text(entry.completed ? "本地作品 · 可另存" : "原片保留 · 可重试导出").font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button(entry.completed ? "预览" : "重试") {
                  Task { await controller.showResult(entry) }
                }
                Button {
                  controller.delete(entry)
                } label: {
                  Image(systemName: "trash").frame(width: 12)
                }.accessibilityLabel("删除这段本地录屏").help("删除本地作品")
              }
            }
            if controller.recent.count > 20 {
              Button("在Finder中查看全部 \(controller.recent.count) 段录屏") {
                NSWorkspace.shared.open(controller.root)
              }
            }
          }
        }.padding(.horizontal, 24).padding(.bottom, 20).disabled(controller.isBusy)
      }
      if let error = controller.error {
        VStack(alignment: .leading, spacing: 8) {
          Text(error).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(
            horizontal: false, vertical: true)
          HStack {
            Button("屏幕权限设置") { controller.store.openPermissionSettings() }
            Button("麦克风权限设置") {
              NSWorkspace.shared.open(
                URL(
                  string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }.disabled(controller.isBusy)
          }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(
          Color.orange.opacity(0.05)
        ).padding(.horizontal, 24)
      }
      Divider()
      HStack {
        Text(controller.options.shortcut.display + " 呼出 / 停止").font(.system(size: 10))
          .foregroundStyle(.secondary)
        Spacer()
        Button(controller.isBusy ? "取消准备" : "关闭") {
          if controller.isBusy {
            controller.cancelPreparation()
          } else {
            NSApp.keyWindow?.performClose(nil)
          }
        }.disabled(controller.phase == .starting || controller.phase == .finishing)
        Button(
          controller.isBusy
            ? controller.stateLabel
            : (controller.options.scope == .display ? "开始录屏" : "框选录屏")
        ) { controller.beginQuick() }.buttonStyle(CaptureActionStyle(primary: true)).disabled(
          controller.isBusy
        ).keyboardShortcut(.defaultAction)
      }.padding(20)
    }.frame(minWidth: 560, minHeight: 620).background(CaptureTheme.chrome).buttonStyle(
      CaptureActionStyle()
    ).tint(CaptureTheme.accent)
  }
  private func audioRow(
    _ title: String, detail: String, symbol: String, enabled: Binding<Bool>, volume: Binding<Double>
  ) -> some View {
    HStack(spacing: 12) {
      Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(
        enabled.wrappedValue ? CaptureTheme.accent : Color.secondary
      ).frame(width: 24)
      VStack(alignment: .leading, spacing: 5) {
        Text(title).font(.system(size: 12, weight: .medium))
        Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      CaptureSlider(value: volume, in: 0...1).frame(width: 85).disabled(!enabled.wrappedValue)
        .accessibilityLabel(title + "音量")
      Text("\(Int(volume.wrappedValue*100))%").font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
      Toggle(title, isOn: enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
    }
  }
}
struct RecordingHUD: View {
  @ObservedObject var controller: RecordingController
  var body: some View {
    HStack(spacing: 14) {
      Circle().fill(controller.phase == .paused ? Color.orange : Color.red).frame(
        width: 8, height: 8)
      VStack(alignment: .leading, spacing: 4) {
        Text(controller.stateLabel).font(.system(size: 11, weight: .medium))
        Text(controller.phase == .countdown ? "\(controller.countdown)" : controller.elapsedLabel)
          .font(.system(size: 19, weight: .medium, design: .monospaced))
      }.frame(width: 96, alignment: .leading)
      VStack(alignment: .leading, spacing: 4) {
        Label(controller.options.computerAudio ? "电脑声音 开" : "电脑声音 关", systemImage: "speaker.wave.2")
        Label(controller.options.microphone ? "麦克风 开" : "麦克风 关", systemImage: "mic")
      }.font(.system(size: 10)).foregroundStyle(.secondary)
      Spacer(minLength: 0)
      if controller.isRecording {
        Button(controller.phase == .paused ? "继续" : "暂停") { controller.togglePause() }
        Button {
          Task { await controller.finish() }
        } label: {
          Label("停止", systemImage: "stop.fill")
        }.buttonStyle(CaptureActionStyle(primary: true, destructive: true))
      } else if controller.phase == .countdown {
        Button("调整") { controller.adjustPreparation() }
        Button("取消") { controller.cancelPreparation() }
      } else {
        ProgressView().controlSize(.small)
      }
    }.padding(.horizontal, 18).frame(width: 510, height: 72).background(
      CaptureTheme.chrome, in: RoundedRectangle(cornerRadius: 15)
    ).overlay(RoundedRectangle(cornerRadius: 15).stroke(CaptureTheme.border)).buttonStyle(
      CaptureActionStyle()
    ).tint(CaptureTheme.accent)
  }
}
struct RecordingResultView: View {
  @ObservedObject var controller: RecordingController
  let entry: RecordingEntry
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("录屏已完成").font(.system(size: 20, weight: .semibold))
        Spacer()
        Text("MP4").font(.caption).foregroundStyle(.secondary)
      }
      RecordingPlayer(url: entry.url).frame(minHeight: 280).background(
        CaptureTheme.canvas, in: RoundedRectangle(cornerRadius: 12)
      ).clipShape(RoundedRectangle(cornerRadius: 12))
      Text(controller.resultInfo).font(.system(size: 11)).foregroundStyle(.secondary)
      if let error = controller.error {
        Text(error).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(
          horizontal: false, vertical: true)
      }
      HStack {
        Button("再录一段") { controller.beginQuick() }
        Spacer()
        Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
        Button("复制文件") { controller.copyResult(entry) }
        Button("另存为…") { controller.saveResult(entry) }.buttonStyle(
          CaptureActionStyle(primary: true))
      }.disabled(controller.fileBusy)
      Text("关闭仍保留本地作品，可从「录制屏幕 → 最近录屏」找回。").font(.system(size: 10)).foregroundStyle(.tertiary)
    }.padding(24).frame(minWidth: 620, minHeight: 480).background(CaptureTheme.chrome).buttonStyle(
      CaptureActionStyle()
    ).tint(CaptureTheme.accent)
  }
}
struct RecordingPlayer: NSViewRepresentable {
  let url: URL
  func makeNSView(context: Context) -> RecordingPlayerHost { RecordingPlayerHost(url: url) }
  func updateNSView(_ view: RecordingPlayerHost, context: Context) {}
  static func dismantleNSView(_ view: RecordingPlayerHost, coordinator: ()) { view.stop() }
}
final class RecordingPlayerHost: NSView {
  let video = AVPlayerView()
  private let poster = NSImageView()
  private let play = CapturePanelButton(caption: "", target: nil, action: nil)
  private var imageTask: Task<Void, Never>?
  init(url: URL) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = CaptureTheme.canvasNS.cgColor
    video.isHidden = true
    video.controlsStyle = .inline
    video.videoGravity = .resizeAspect
    video.player = AVPlayer(url: url)
    poster.imageScaling = .scaleProportionallyUpOrDown
    play.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
    play.imagePosition = .imageOnly
    play.target = self
    play.action = #selector(startPlaying)
    play.toolTip = "播放录屏"
    play.setAccessibilityLabel("播放录屏")
    play.keyEquivalent = " "
    addSubview(video)
    addSubview(poster)
    addSubview(play)
    imageTask = Task { [weak self] in
      let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 1600, height: 1000)
      do {
        let frame = try await generator.image(at: .zero)
        guard !Task.isCancelled else { return }
        self?.poster.image = NSImage(cgImage: frame.image, size: .zero)
      } catch {}
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func layout() {
    super.layout()
    video.frame = bounds
    poster.frame = bounds
    play.frame = CGRect(x: bounds.midX - 25, y: bounds.midY - 25, width: 50, height: 50)
  }
  @objc private func startPlaying() {
    poster.isHidden = true
    video.isHidden = false
    play.isHidden = true
    video.player?.play()
    window?.makeFirstResponder(video)
  }
  func stop() {
    imageTask?.cancel()
    imageTask = nil
    video.player?.pause()
    video.player = nil
  }
}
