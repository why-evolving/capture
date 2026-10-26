import AppKit
import CaptureCore
import SwiftUI

/// A single contextual surface for choosing, configuring and starting a recording.
struct RecordingQuickControls: View {
  @ObservedObject var controller: RecordingController
  private func option<T>(_ key: WritableKeyPath<RecordingOptions, T>) -> Binding<T> {
    Binding(get: { controller.options[keyPath: key] }, set: { controller.setQuickOption(key, $0) })
  }
  var body: some View {
    VStack(spacing: 10) {
      HStack(spacing: 10) {
        CaptureSegments(
          "录屏范围",
          selection: Binding(
            get: { controller.options.scope }, set: { controller.chooseQuickScope($0) }),
          options: RecordingScope.allCases.map { ($0, $0.label) }
        ).frame(width: 168)
        CaptureSegments(
          "录屏开始方式",
          selection: Binding(
            get: { controller.effectiveAdjustment }, set: { controller.setQuickAdjustment($0) }),
          options: [(false, "松手即录"), (true, "框选调整")]
        ).frame(width: 200)
        Spacer(minLength: 0)
        if controller.quickReady {
          Button {
            controller.confirmQuickSelection()
          } label: {
            Label("开始录制", systemImage: "record.circle").frame(minWidth: 72)
          }
          .buttonStyle(CaptureActionStyle(primary: true, destructive: true)).keyboardShortcut(
            .defaultAction)
        } else {
          Text("拖动框选").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        Button {
          controller.cancelPreparation()
        } label: {
          Image(systemName: "xmark").frame(width: 12)
        }.help("取消本次录屏（Esc）").accessibilityLabel("取消本次录屏")
      }
      HStack(spacing: 8) {
        Toggle(isOn: option(\.computerAudio)) { Label("电脑声音", systemImage: "speaker.wave.2") }
          .toggleStyle(.switch).controlSize(.small).fixedSize()
        Toggle(isOn: option(\.microphone)) { Label("麦克风", systemImage: "mic") }.toggleStyle(.switch)
          .controlSize(.small).fixedSize()
        Divider().frame(height: 18)
        CaptureChoice(
          "录屏画质", selection: option(\.quality), options: [(.standard, "1080p"), (.high, "4K")]
        ).frame(width: 85)
        CaptureChoice(
          "录屏帧率", selection: option(\.framesPerSecond), options: [(30, "30 fps"), (60, "60 fps")]
        ).frame(width: 80)
        HStack(spacing: 4) {
          Image(systemName: "timer").foregroundStyle(.secondary)
          CaptureChoice(
            "开始前倒计时", selection: option(\.countdown), options: [(0, "立即"), (3, "3 秒"), (5, "5 秒")]
          ).frame(width: 72)
        }
        Button {
          controller.quickMore.toggle()
        } label: {
          Image(systemName: controller.quickMore ? "chevron.up" : "ellipsis").frame(width: 12)
        }.help("设备、音量和鼠标指针").accessibilityLabel(controller.quickMore ? "收起更多录屏设置" : "更多录屏设置")
      }.font(.system(size: 11))
      if controller.quickMore {
        Divider()
        HStack(spacing: 10) {
          Text("麦克风").foregroundStyle(.secondary)
          CaptureChoice(
            "麦克风设备",
            selection: Binding(
              get: { controller.options.microphoneID ?? "" },
              set: { controller.setQuickOption(\.microphoneID, $0.isEmpty ? nil : $0) }),
            options: [("", "系统默认麦克风")] + controller.devices.map { ($0.uniqueID, $0.localizedName) }
          ).disabled(!controller.options.microphone)
          Button {
            controller.refreshDevices()
          } label: {
            Image(systemName: "arrow.clockwise").frame(width: 12)
          }.accessibilityLabel("刷新麦克风设备")
          Toggle("包含鼠标", isOn: option(\.includeCursor)).fixedSize()
        }.font(.system(size: 11))
        HStack(spacing: 16) {
          volume(
            "电脑音量", enabled: controller.options.computerAudio, binding: option(\.computerVolume))
          volume(
            "麦克风音量", enabled: controller.options.microphone, binding: option(\.microphoneVolume))
        }
      }
      if let error = controller.error {
        HStack(spacing: 10) {
          Text(error).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2).frame(
            maxWidth: .infinity, alignment: .leading)
          Button("权限设置") {
            NSWorkspace.shared.open(
              URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
              )!)
          }
        }
      }
      Text(controller.quickLabel).font(.system(size: 10)).foregroundStyle(.secondary).frame(
        maxWidth: .infinity, alignment: .leading)
    }.padding(12).frame(width: 660, height: controller.quickPanelHeight)
      .background(CaptureTheme.chrome, in: RoundedRectangle(cornerRadius: 14))
      .overlay(RoundedRectangle(cornerRadius: 14).stroke(CaptureTheme.border))
      .buttonStyle(CaptureActionStyle()).tint(CaptureTheme.accent)
      .onExitCommand { controller.cancelPreparation() }
  }
  private func volume(_ title: String, enabled: Bool, binding: Binding<Double>) -> some View {
    HStack(spacing: 8) {
      Text(title).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
      CaptureSlider(value: binding, in: 0...1).accessibilityLabel(title)
      Text("\(Int(binding.wrappedValue*100))%").font(.system(size: 10, design: .monospaced)).frame(
        width: 30, alignment: .trailing)
    }.disabled(!enabled)
  }
}

/// The same two-mode concept as screenshots, independently persisted for recording.
struct RecordingModePicker: View {
  @ObservedObject var controller: RecordingController
  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text("录屏选区方式").font(.system(size: 13, weight: .medium))
      CaptureSegments(
        "录屏选区方式",
        selection: Binding(
          get: { controller.options.allowsRecordingAdjustment },
          set: { controller.setRecordingAdjustmentDefault($0) }),
        options: [(false, "快速录屏"), (true, "框选调整")])
      Text(
        controller.options.allowsRecordingAdjustment
          ? "松手后保留选区；拖动框内移动，拖动边角调整大小，回车开始录制。" : "框选松手后按设定倒计时录制；需要微调时可切换为框选调整。"
      )
      .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(
        horizontal: false, vertical: true)
    }.disabled(controller.isBusy)
  }
}
