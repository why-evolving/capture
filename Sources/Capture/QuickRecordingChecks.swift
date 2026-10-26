import AppKit
import CaptureCore
import Combine
import ScreenCaptureKit
import SwiftUI

@MainActor enum QuickRecordingChecks {
  static func run(app: AppController, directory: URL) async throws {
    guard CGPreflightScreenCaptureAccess(),
      (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool
        != true
    else { throw DeveloperChecks.CheckBlocked("快捷录屏原生检查需要解锁与屏幕录制权限。") }
    func require(_ value: Bool, _ text: String) throws {
      if !value { throw DeveloperChecks.CheckFailure(text) }
    }
    var stage = "entry"
    func wait(_ condition: () -> Bool) async throws {
      for _ in 0..<150 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(40))
      }
      throw DeveloperChecks.CheckFailure("快捷录屏状态等待超时：\(stage)")
    }
    let c = app.recording
    var transitions: [String] = []
    let token = c.$phase.sink { transitions.append($0.rawValue) }
    defer {
      token.cancel()
      c.shutdown()
    }
    // The selection freeze is generated, not a desktop screenshot. Every display gets an owned bitmap.
    var frames: [CGDirectDisplayID: FrozenFrame] = [:]
    for screen in NSScreen.screens {
      guard
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
          .uint32Value
      else { continue }
      let w = Int(screen.frame.width * screen.backingScaleFactor)
      let h = Int(screen.frame.height * screen.backingScaleFactor)
      guard
        let context = CGContext(
          data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { throw RecordingError.message("测试图分配失败") }
      context.setFillColor(NSColor(srgbRed: 0.90, green: 0.94, blue: 0.99, alpha: 1).cgColor)
      context.fill(CGRect(x: 0, y: 0, width: w, height: h))
      context.draw(
        SampleImage.make(), in: CGRect(x: w / 5, y: h / 5, width: w * 3 / 5, height: h * 3 / 5))
      frames[id] = try FrozenFrame(image: context.makeImage()!, pointSize: screen.frame.size)
    }
    c.selectionContext = {
      RecordingController.SelectionContext(
        frames: frames,
        windows: [
          CaptureWindow(
            id: 900001, title: "Capture生成样例", frame: CGRect(x: 170, y: 140, width: 420, height: 260)
          )
        ])
    }
    let own = NSWindow(
      contentRect: CGRect(x: 240, y: 240, width: 400, height: 240), styleMask: [.borderless],
      backing: .buffered, defer: false)
    own.isReleasedWhenClosed = false
    own.backgroundColor = .systemBlue
    own.level = .floating
    own.orderFrontRegardless()
    defer { own.close() }
    try await Task.sleep(for: .milliseconds(220))
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    guard let window = content.windows.first(where: { $0.windowID == CGWindowID(own.windowNumber) })
    else { throw DeveloperChecks.CheckFailure("未找到快捷录屏自有样例窗口") }
    let filter = SCContentFilter(desktopIndependentWindow: window)
    c.capturePlan = { _, _ in
      RecordingController.CapturePlan(
        filter: filter,
        sourceSize: CGSize(
          width: 400 * Double(filter.pointPixelScale), height: 240 * Double(filter.pointPixelScale)),
        sourceRect: nil, excludeOwnAudio: false)
    }
    var options = RecordingOptions()
    options.computerAudio = false
    options.microphone = false
    options.countdown = 3
    c.options = options
    func active() throws -> SelectionView {
      guard
        let v = c.selectionViewsForChecks.first(where: { $0.window?.isKeyWindow == true })
          ?? c.selectionViewsForChecks.first
      else { throw DeveloperChecks.CheckFailure("没有直接进入录屏选区") }
      return v
    }
    func panel() throws -> NSWindow {
      guard
        let p = NSApp.windows.first(where: {
          $0.contentView is NSHostingView<RecordingQuickControls> && $0.isVisible
        })
      else { throw DeveloperChecks.CheckFailure("快捷浮条没有显示") }
      return p
    }
    func event(_ type: NSEvent.EventType, _ point: CGPoint, _ view: SelectionView) -> NSEvent {
      let converted = view.convert(point, to: nil)
      return NSEvent.mouseEvent(
        with: type, location: converted, modifierFlags: [], timestamp: 0,
        windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
        pressure: 1)!
    }
    func drag(_ view: SelectionView, from: CGPoint, to: CGPoint) {
      let window = view.window!
      window.sendEvent(event(.leftMouseDown, from, view))
      window.sendEvent(event(.leftMouseDragged, to, view))
      window.sendEvent(event(.leftMouseUp, to, view))
    }
    c.hotkey()
    try await wait { c.phase == .selecting && !c.selectionViewsForChecks.isEmpty }
    try require(!c.hasSetupWindow && !(try active()).adjustable, "快捷键仍先打开配置或默认不是松手即录")
    try RecordingChecks.snapshot(try panel(), name: "quick-ready", directory: directory)
    c.setQuickOption(\.microphone, true)
    try require(app.store.preferences.recording?.microphone == true, "就地麦克风没有绑定")
    c.setQuickOption(\.microphone, false)
    c.setQuickOption(\.quality, .high)
    c.setQuickOption(\.framesPerSecond, 60)
    c.quickMore = true
    try await Task.sleep(for: .milliseconds(80))
    try RecordingChecks.snapshot(try panel(), name: "quick-more", directory: directory)
    let p = try panel()
    func descendants(_ view: NSView) -> [NSView] {
      [view] + view.subviews.flatMap { descendants($0) }
    }
    guard
      let popup = descendants(p.contentView!).compactMap({ $0 as? CapturePopup }).first(where: {
        $0.itemTitles.contains("4K")
      }), let menu = popup.menu
    else { throw DeveloperChecks.CheckFailure("快捷画质下拉不可达") }
    var menuAbove = false
    let observer = NotificationCenter.default.addObserver(
      forName: NSMenu.didBeginTrackingNotification, object: menu, queue: .main
    ) { _ in MainActor.assumeIsolated { menuAbove = p.level == .statusBar } }
    let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
      MainActor.assumeIsolated { menu.cancelTracking() }
    }
    RunLoop.main.add(timer, forMode: .common)
    popup.performClick(nil)
    NotificationCenter.default.removeObserver(observer)
    try require(
      menuAbove && p.level.rawValue > NSWindow.Level.screenSaver.rawValue, "选区菜单层级没有恢复或被遮挡")
    c.quickMore = false
    drag(try active(), from: CGPoint(x: 110, y: 100), to: CGPoint(x: 460, y: 320))
    try await wait { c.phase == .countdown }
    try require(
      !c.hasSetupWindow && c.target?.rectangle == CGRect(x: 110, y: 100, width: 350, height: 220),
      "松手没有直接进入倒计时或范围错误")
    c.adjustPreparation()
    try await wait { c.phase == .selecting && c.quickReady }
    try require(
      c.effectiveAdjustment && c.options.adjustBeforeRecording == nil
        && (try active()).rectangle == CGRect(x: 110, y: 100, width: 350, height: 220),
      "倒计时调整丢范围或改了默认模式")
    let v = try active()
    drag(v, from: CGPoint(x: 200, y: 180), to: CGPoint(x: 225, y: 195))
    try require(
      c.phase == .selecting && v.rectangle == CGRect(x: 135, y: 115, width: 350, height: 220),
      "调整模式没有保留拖动或提前录制")
    try RecordingChecks.snapshot(try panel(), name: "quick-adjusted", directory: directory)
    c.options.microphone = true
    c.audioAccess = RecordingAudioAccess(
      status: { .denied }, request: { false }, validateDevice: { _ in })
    c.confirmQuickSelection()
    try await wait { c.phase == .selecting && c.error != nil && c.quickReady }
    try require(!c.hasSetupWindow && c.options.microphone, "授权失败没有就地保留配置")
    try RecordingChecks.snapshot(try panel(), name: "quick-error", directory: directory)
    c.setQuickOption(\.microphone, false)
    c.audioAccess = .live
    c.error = nil
    stage = "error-retry"
    c.confirmQuickSelection()
    try await wait { c.phase == .countdown }
    c.cancelPreparation()
    try await Task.sleep(for: .milliseconds(3300))
    try require(
      c.phase == .configuring && !c.hasSetupWindow && !transitions.contains("recording"),
      "取消后旧倒计时仍录制或打开了配置窗口")
    stage = "window"
    c.options.scope = .window
    c.beginQuick()
    try await wait { c.phase == .selecting && !c.selectionViewsForChecks.isEmpty }
    let wv = try active()
    wv.mouseMoved(with: event(.mouseMoved, CGPoint(x: 220, y: 180), wv))
    drag(wv, from: CGPoint(x: 220, y: 180), to: CGPoint(x: 220, y: 180))
    try await wait { c.phase == .countdown }
    try require(c.target?.windowID == 900001, "窗口快速点选没有保留窗口身份")
    c.cancelPreparation()
    stage = "full-screen"
    c.options.scope = .area
    c.beginQuick()
    try await wait { c.phase == .selecting && !c.selectionViewsForChecks.isEmpty }
    c.chooseQuickScope(.display)
    try await wait { c.phase == .countdown }
    try require(c.target?.rectangle.size == c.target?.screen.frame.size, "全屏快捷范围错误")
    c.adjustPreparation()
    try await wait { c.phase == .selecting && c.quickReady }
    let fv = try active()
    drag(
      fv, from: CGPoint(x: fv.bounds.maxX - 1, y: fv.bounds.midY),
      to: CGPoint(x: fv.bounds.maxX - 180, y: fv.bounds.midY))
    try require(c.options.scope == .area && c.phase == .selecting, "全屏改局部没有转区域")
    c.cancelPreparation()
    c.showSetup()
    try require(c.hasSetupWindow, "显式设置入口丢失")
    c.options.scope = .area
    c.beginQuick()
    try await wait { c.phase == .selecting && !c.selectionViewsForChecks.isEmpty }
    try require(!c.hasSetupWindow, "从设置开始仍要返回大窗口")
    c.cancelPreparation()
    stage = "persistent-adjustment"
    let screenshotOptions = app.store.preferences.captureOptions
    c.setRecordingAdjustmentDefault(true)
    c.options.scope = .area
    c.hotkey()
    try await wait { c.phase == .selecting && !c.selectionViewsForChecks.isEmpty }
    let adjustedView = try active()
    try require(
      adjustedView.adjustable && app.store.preferences.recording?.allowsRecordingAdjustment == true,
      "设置中的录屏框选调整没有持久化生效")
    drag(adjustedView, from: CGPoint(x: 150, y: 130), to: CGPoint(x: 550, y: 390))
    try require(adjustedView.ready && c.phase == .selecting, "框选调整松手后没有保留选区")
    drag(adjustedView, from: CGPoint(x: 300, y: 240), to: CGPoint(x: 315, y: 250))
    for handle in SelectionHandle.allCases {
      let before = adjustedView.rectangle
      let point = handle.point(in: before)
      drag(adjustedView, from: point, to: CGPoint(x: point.x + 6, y: point.y + 4))
      try require(adjustedView.rectangle != before && c.phase == .selecting, "录屏边角无法调整：\(handle)")
    }
    try RecordingChecks.snapshot(try panel(), name: "quick-resizable-mode", directory: directory)
    let selectedRect = adjustedView.rectangle
    let enter = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: adjustedView.window!.windowNumber, context: nil, characters: "\r",
      charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    adjustedView.window?.makeFirstResponder(adjustedView)
    adjustedView.window?.sendEvent(enter)
    try await wait { c.phase == .countdown }
    try require(c.target?.rectangle == selectedRect && !c.hasSetupWindow, "回车没有从调整范围就地开始")
    c.cancelPreparation()
    c.setRecordingAdjustmentDefault(false)
    try require(app.store.preferences.captureOptions == screenshotOptions, "录屏模式覆盖了截图模式")
    stage = "final-recording"
    c.options.countdown = 0
    c.options.scope = .area
    c.beginQuick()
    try await wait { c.phase == .selecting && !c.selectionViewsForChecks.isEmpty }
    drag(try active(), from: CGPoint(x: 100, y: 90), to: CGPoint(x: 450, y: 300))
    try await wait { c.phase == .recording }
    try await Task.sleep(for: .milliseconds(400))
    await c.finish()
    guard let result = c.result else { throw DeveloperChecks.CheckFailure(c.error ?? "快捷链路没有产生视频") }
    _ = try await RecordingFiles.inspect(result.url)
    try RecordingFiles.copy(result.url, to: directory.appendingPathComponent("quick-output.mp4"))
    try require(transitions.filter { $0 == "recording" }.count == 1, "快捷选择重复启动录制")
    let checks = [
      "quick-entry-bypasses-setup", "quick-release-starts-countdown",
      "quick-inline-options-and-menu-level", "quick-adjust-preserves-range-and-default",
      "quick-drag-stays-in-selection", "quick-denial-recovers-inline",
      "quick-cancel-invalidates-old-countdown", "quick-window-retains-identity",
      "quick-fullscreen-to-area", "quick-explicit-settings-and-start",
      "quick-own-window-produces-video-once", "quick-persistent-adjustment-setting",
      "quick-all-eight-handles-and-move", "quick-adjustment-return-starts-in-place",
    ]
    try JSONSerialization.data(
      withJSONObject: [
        "result": "passed", "checks": checks, "transitions": transitions,
        "screenCaptureAttempted": true, "generalClipboardModified": false,
        "hardwareMicrophoneCaptured": false,
        "selectionSource":
          "Generated bitmaps for each display; never a third-party desktop snapshot",
        "videoSource": "Include-only owned blue sample window; microphone/computer audio disabled",
        "output": "quick-output.mp4",
      ], options: [.prettyPrinted, .sortedKeys]
    ).write(to: directory.appendingPathComponent("quick-recording-checks.json"))
  }
}
