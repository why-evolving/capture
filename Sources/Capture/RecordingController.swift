import AVKit
import AppKit
import CaptureCore
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class RecordingController: NSObject, ObservableObject, NSWindowDelegate {
  enum Phase: String {
    case configuring, selecting, authorizing, countdown, starting, recording, paused, finishing,
      completed
  }
  @Published var options: RecordingOptions {
    didSet {
      if options.isValid { store.update { $0.recording = options } }
      if phase == .selecting { selection.updateRecordingAdjustment(effectiveAdjustment) }
    }
  }
  @Published private(set) var phase: Phase = .configuring
  @Published var error: String?
  @Published private(set) var seconds = 0.0
  @Published private(set) var countdown = 0
  @Published private(set) var target: ScreenSelection?
  @Published private(set) var devices: [AVCaptureDevice] = []
  @Published private(set) var recent: [RecordingEntry] = []
  @Published private(set) var result: RecordingEntry?
  @Published private(set) var resultInfo = ""
  @Published private(set) var fileBusy = false
  let store: AppStore
  let root: URL
  struct CapturePlan {
    let filter: SCContentFilter
    let sourceSize: CGSize
    let sourceRect: CGRect?
    var excludeOwnAudio = true
  }
  var audioAccess = RecordingAudioAccess.live
  var capturePlan: ((RecordingOptions, ScreenSelection?) async throws -> CapturePlan)?
  var canBegin: (() -> Bool)?
  var onChange: (() -> Void)?
  var onShortcut: ((Shortcut) -> String?)?
  struct SelectionContext {
    let frames: [CGDirectDisplayID: FrozenFrame]
    let windows: [CaptureWindow]
  }
  var selectionContext: (() async throws -> SelectionContext)?
  @Published private(set) var quickReady = false
  @Published private(set) var quickLabel = "拖动框选录屏范围"
  @Published var quickMore = false { didSet { positionQuickPanel() } }
  private(set) var quickEntry = false
  private var adjustmentOverride = false
  var effectiveAdjustment: Bool { adjustmentOverride || options.allowsRecordingAdjustment }
  private let selection = SelectionController()
  private var quickPanel: SelectionPanel?
  private var quickScreen: NSScreen?
  private var quickRectangle = CGRect.zero
  private var quickDragging = false
  private var quickMenuObservers: [NSObjectProtocol] = []
  private var quickMenuTracking = false
  var quickPanelHeight: CGFloat { 132 + (quickMore ? 112 : 0) + (error == nil ? 0 : 64) }
  var hasSetupWindow: Bool { setupWindow?.isVisible == true }
  var selectionViewsForChecks: [SelectionView] {
    NSApp.windows.filter { $0.isVisible }.compactMap { $0.contentView as? SelectionView }.filter {
      $0.externalRecordingControls
    }
  }

  private var engine: RecordingEngine?
  private var entry: RecordingEntry?
  private var task: Task<Void, Never>?
  private var session: UUID?
  private var timer: Timer?
  private var workspaceObserver: NSObjectProtocol?
  private var screenObserver: NSObjectProtocol?
  private var deviceObserver: NSObjectProtocol?
  private var lockObserver: NSObjectProtocol?
  private var setupWindow: NSWindow?
  private var hud: NSPanel?
  private var resultWindow: NSWindow?
  private(set) var savePanel: NSSavePanel?
  var isBusy: Bool { ![Phase.configuring, .completed].contains(phase) }
  var isRecording: Bool { phase == .recording || phase == .paused }
  var stateLabel: String {
    switch phase {
    case .configuring, .completed: "准备录屏"
    case .selecting: "选择范围"
    case .authorizing: "检查权限"
    case .countdown: "\(countdown) 秒后开始"
    case .starting: "正在启动"
    case .recording: "正在录制"
    case .paused: "已暂停"
    case .finishing: "正在保存"
    }
  }
  var elapsedLabel: String { Self.timeLabel(seconds) }
  static func timeLabel(_ seconds: Double) -> String {
    let n = max(0, Int(seconds))
    return n >= 3600
      ? String(format: "%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60)
      : String(format: "%02d:%02d", n / 60, n % 60)
  }
  var targetLabel: String {
    guard let target else { return options.scope == .display ? "开始时录制鼠标所在屏幕" : "尚未选择范围" }
    let size =
      options.outputSize(
        source: CGSize(
          width: target.rectangle.width * target.scale,
          height: target.rectangle.height * target.scale)) ?? .zero
    return
      "\(target.windowID == nil ? options.scope.label : "窗口") · \(Int(size.width)) × \(Int(size.height)) px"
  }
  init(store: AppStore, root: URL? = nil) {
    self.store = store
    self.root = root ?? RecordingFiles.defaultRoot
    options =
      store.preferences.recording
      ?? RecordingOptions.defaults(captureShortcut: store.preferences.shortcut)
    super.init()
  }
  private func changed() { onChange?() }
  func refreshDevices() { devices = RecordingEngine.devices() }
  func refreshRecent() {
    let root = root
    Task {
      do {
        let clips = try await Task.detached { try RecordingFiles.entries(root: root) }.value
        recent = clips
      } catch { self.error = error.localizedDescription }
    }
  }
  func showSetup() {
    if isBusy {
      showActiveControls()
      return
    }
    phase = .configuring
    changed()
    refreshDevices()
    refreshRecent()
    if let setupWindow {
      setupWindow.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 600, height: 720),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.title = "录制屏幕"
    window.minSize = CGSize(width: 560, height: 620)
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.contentView = NSHostingView(rootView: RecordingSetupView(controller: self))
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    setupWindow = window
  }
  func hotkey() {
    if isRecording {
      Task { await finish() }
      return
    }
    if phase == .countdown || phase == .selecting {
      cancelPreparation()
      return
    }
    guard !isBusy, canBegin?() ?? true else { return }
    beginQuick()
  }
  func chooseScope(_ scope: RecordingScope) {
    guard !isBusy else { return }
    options.scope = scope
    target = nil
    error = nil
  }
  func selectTarget() { beginQuick() }
  func showActiveControls() {
    if phase == .selecting {
      quickPanel?.orderFrontRegardless()
      selection.activateRecordingSelection()
    } else {
      showHUD()
    }
  }
  func beginQuick(
    forceAdjustment: Bool = false, restoring: ScreenSelection? = nil, preserveError: Bool = false
  ) {
    guard !isBusy, canBegin?() ?? true else { return }
    store.refreshPermission()
    guard store.permissionGranted else {
      error = "需要屏幕录制权限，请在系统设置中允许Capture。"
      showSetup()
      return
    }
    quickEntry = true
    adjustmentOverride = forceAdjustment
    quickReady = false
    quickMore = false
    target = restoring?.withoutFrame
    if !preserveError { error = nil }
    setupWindow?.orderOut(nil)
    resultWindow?.close()
    quickScreen =
      restoring?.screen ?? NSScreen.screens.first(where: {
        $0.frame.contains(NSEvent.mouseLocation)
      }) ?? NSScreen.main
    quickRectangle = .zero
    quickDragging = false
    if options.scope == .display && !effectiveAdjustment, let screen = quickScreen,
      let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
        .uint32Value
    {
      target = ScreenSelection(
        displayID: id, rectangle: CGRect(origin: .zero, size: screen.frame.size),
        scale: screen.backingScaleFactor, screen: screen)
      start()
      return
    }
    phase = .selecting
    changed()
    refreshDevices()
    let token = UUID()
    session = token
    task = Task {
      do {
        let context: SelectionContext
        if let selectionContext {
          context = try await selectionContext()
        } else {
          let displays = NSScreen.screens.compactMap {
            screen -> (id: CGDirectDisplayID, scale: Double)? in
            guard
              let id =
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value
            else { return nil }
            return (id, Double(screen.backingScaleFactor))
          }
          let frozen = try await ScreenCaptureService.freeze(
            displays: displays, includeCursor: false)
          context = SelectionContext(frames: frozen.frames, windows: frozen.windows)
        }
        guard session == token, !Task.isCancelled else { return }
        showQuickPanel()
        selection.begin(
          windows: context.windows, windowMode: options.scope == .window,
          adjustable: effectiveAdjustment,
          confirmTitle: "开始录制", frames: context.frames, recording: true,
          externalRecordingControls: true, initialSelection: restoring,
          onGeometryChange: { [weak owner = self] screen, rect, ready, dragging, windowMode in
            owner?.updateQuickGeometry(
              screen: screen, rect: rect, ready: ready, dragging: dragging, windowMode: windowMode)
          },
          onRecordingModeChange: { [weak owner = self] window in
            owner?.options.scope = window ? .window : .area
          }
        ) { [weak owner = self] selected in
          guard let owner, owner.session == token else { return }
          owner.closeQuickPanel()
          owner.session = nil
          owner.phase = .configuring
          guard let selected else {
            owner.quickEntry = false
            owner.changed()
            return
          }
          owner.target = selected.withoutFrame
          owner.changed()
          owner.start()
        }
        if options.scope == .display, let screen = quickScreen {
          selection.selectRecordingDisplay(screen)
        }
      } catch {
        guard session == token else { return }
        session = nil
        phase = .configuring
        self.error = error.localizedDescription
        closeQuickPanel()
        quickEntry = false
        changed()
        showSetup()
      }
    }
  }
  func chooseQuickScope(_ scope: RecordingScope) {
    guard phase == .selecting else { return }
    let currentScreen = quickScreen
    options.scope = scope
    selection.updateRecordingMode(window: scope == .window)
    if scope == .display, let screen = currentScreen {
      selection.selectRecordingDisplay(screen)
      if !effectiveAdjustment { selection.confirmRecordingSelection() }
    }
  }
  func setRecordingAdjustmentDefault(_ adjusted: Bool) {
    guard !isBusy || phase == .selecting else { return }
    adjustmentOverride = false
    options.adjustBeforeRecording = adjusted
    if phase == .selecting {
      selection.updateRecordingAdjustment(adjusted)
      selection.activateRecordingSelection()
    }
  }
  func setQuickAdjustment(_ adjusted: Bool) { setRecordingAdjustmentDefault(adjusted) }
  func setQuickOption<T>(_ key: WritableKeyPath<RecordingOptions, T>, _ value: T) {
    guard phase == .selecting else { return }
    options[keyPath: key] = value
    if !quickMenuTracking { selection.activateRecordingSelection() }
  }
  func confirmQuickSelection() {
    guard phase == .selecting else { return }
    selection.confirmRecordingSelection()
  }
  func adjustPreparation() {
    guard phase == .countdown else { return }
    let previous = target
    resetPreparation()
    beginQuick(forceAdjustment: true, restoring: previous)
  }
  private func updateQuickGeometry(
    screen: NSScreen, rect: CGRect, ready: Bool, dragging: Bool, windowMode: Bool
  ) {
    guard phase == .selecting else { return }
    quickScreen = screen
    quickRectangle = rect
    quickReady = ready
    quickDragging = dragging
    if ready, options.scope == .display, rect != CGRect(origin: .zero, size: screen.frame.size) {
      options.scope = .area
    }
    if ready, options.scope == .window, !windowMode { options.scope = .area }
    quickLabel =
      ready
      ? "\(Int(rect.width*screen.backingScaleFactor)) × \(Int(rect.height*screen.backingScaleFactor)) px · 框内拖动移动，边角缩放，回车开始"
      : (effectiveAdjustment
        ? "拖动框选，调整后回车开始 · Esc取消" : "拖动框选，松手后\(options.countdown == 0 ? "立即录制":"倒计时录制") · Esc取消")
    positionQuickPanel()
  }
  private func showQuickPanel() {
    closeQuickPanel()
    let panel = SelectionPanel(
      contentRect: CGRect(x: 0, y: 0, width: 660, height: quickPanelHeight),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.contentView = NSHostingView(rootView: RecordingQuickControls(controller: self))
    quickPanel = panel
    positionQuickPanel()
    for (name, tracking) in [
      (NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false),
    ] {
      quickMenuObservers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
          [weak self] _ in
          MainActor.assumeIsolated {
            guard let self, self.phase == .selecting else { return }
            self.quickMenuTracking = tracking
            self.quickPanel?.level =
              tracking
              ? .statusBar : NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            self.selection.setRecordingMenuTracking(tracking)
          }
        })
    }
  }
  private func positionQuickPanel() {
    guard let panel = quickPanel, let screen = quickScreen else { return }
    let visible = screen.visibleFrame
    let bounds = CGRect(
      x: visible.minX - screen.frame.minX + 10, y: screen.frame.maxY - visible.maxY + 10,
      width: visible.width - 20, height: visible.height - 20)
    let rect: CGRect
    if quickReady {
      rect = SelectionGeometry.toolbarFrame(
        for: quickRectangle, size: CGSize(width: 660, height: quickPanelHeight), in: bounds)
    } else {
      rect = CGRect(
        x: bounds.midX - 330, y: bounds.maxY - quickPanelHeight - 6, width: 660,
        height: quickPanelHeight)
    }
    panel.setFrame(
      CGRect(
        x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width,
        height: rect.height), display: true)
    if quickDragging { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
  }
  private func closeQuickPanel() {
    quickMenuObservers.forEach { NotificationCenter.default.removeObserver($0) }
    quickMenuObservers = []
    quickMenuTracking = false
    quickPanel?.orderOut(nil)
    quickPanel?.close()
    quickPanel = nil
  }
  func start() {
    guard !isBusy, canBegin?() ?? true else { return }
    if options.scope != .display && target == nil {
      selectTarget()
      return
    }
    store.refreshPermission()
    guard store.permissionGranted else {
      error = "需要屏幕录制权限，请在系统设置中允许Capture。"
      return
    }
    phase = .authorizing
    error = nil
    changed()
    let token = UUID()
    session = token
    let options = options
    let root = root
    task = Task {
      do {
        guard options.isValid else { throw RecordingError.message("录屏选项无效。") }
        try await audioAccess.prepare(options)
        try Task.checkCancellation()
        guard session == token else { return }
        let plan: CapturePlan
        if let capturePlan {
          plan = try await capturePlan(options, target)
        } else {
          plan = try await makePlan(options: options, target: target)
        }
        guard let output = options.outputSize(source: plan.sourceSize) else {
          throw RecordingError.message("范围过小或像素尺寸无效，至少需要16×16像素。")
        }
        let prepared = try await Task.detached {
          try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
          guard RecordingFiles.freeBytes(at: root) >= RecordingLimits.startFreeBytes else {
            throw RecordingError.message("至少需要512MB可用空间才能开始录屏。")
          }
          return try RecordingFiles.create(root: root, options: options)
        }.value
        guard session == token, !Task.isCancelled else {
          try? RecordingFiles.delete(prepared, root: root)
          return
        }
        entry = prepared
        setupWindow?.orderOut(nil)
        resultWindow?.close()
        phase = .countdown
        seconds = 0
        showHUD()
        changed()
        for i in (0..<options.countdown).reversed() {
          countdown = i + 1
          try await Task.sleep(for: .seconds(1))
          try Task.checkCancellation()
        }
        countdown = 0
        guard session == token else { return }
        phase = .starting
        changed()
        let engine = RecordingEngine()
        self.engine = engine
        engine.onError = { [weak owner = self] message in
          Task { @MainActor in
            guard let owner, owner.session == token else { return }
            await owner.finish(reason: message)
          }
        }
        try await engine.start(
          filter: plan.filter, size: output, sourceRect: plan.sourceRect, options: options,
          entry: prepared, excludeOwnAudio: plan.excludeOwnAudio, onProgress: { _ in })
        guard session == token, !Task.isCancelled else {
          await engine.cancel()
          return
        }
        phase = .recording
        changed()
        installObservers()
        beginTimer()
      } catch {
        guard session == token else { return }
        if let engine { await engine.cancel() }
        engine = nil
        // Files that never received video are safe to remove. Writer failures with data remain recoverable.
        if let entry {
          let source = entry.directory.appendingPathComponent("source.mov")
          if ((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < 1024 {
            try? RecordingFiles.delete(entry, root: root)
          }
        }
        self.entry = nil
        session = nil
        phase = .configuring
        hud?.orderOut(nil)
        self.error = error is CancellationError ? nil : error.localizedDescription
        changed()
        if quickEntry {
          beginQuick(forceAdjustment: true, restoring: target, preserveError: true)
        } else {
          showSetup()
        }
      }
    }
  }
  private func makePlan(options: RecordingOptions, target: ScreenSelection?) async throws
    -> CapturePlan
  {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    let filter: SCContentFilter
    let sourceSize: CGSize
    let sourceRect: CGRect?
    if options.scope == .display {
      guard
        let screen = target?.screen ?? NSScreen.screens.first(where: {
          $0.frame.contains(NSEvent.mouseLocation)
        })
          ?? NSScreen.main,
        let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
        let display = content.displays.first(where: { $0.displayID == n.uint32Value })
      else { throw RecordingError.message("所选屏幕已不可用。") }
      filter = SCContentFilter(
        display: display,
        excludingApplications: content.applications.filter {
          $0.processID == ProcessInfo.processInfo.processIdentifier
        }, exceptingWindows: [])
      sourceSize = CGSize(
        width: filter.contentRect.width * Double(filter.pointPixelScale),
        height: filter.contentRect.height * Double(filter.pointPixelScale))
      sourceRect = nil
    } else if let target = target, let windowID = target.windowID {
      guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
        throw RecordingError.message("所选窗口已关闭，请重新选择。")
      }
      filter = SCContentFilter(desktopIndependentWindow: window)
      sourceSize = CGSize(
        width: window.frame.width * Double(filter.pointPixelScale),
        height: window.frame.height * Double(filter.pointPixelScale))
      sourceRect = nil
    } else if let target = target,
      let display = content.displays.first(where: { $0.displayID == target.displayID })
    {
      guard CGRect(origin: .zero, size: target.screen.frame.size).contains(target.rectangle) else {
        throw RecordingError.message("屏幕范围已变化，请重新选择。")
      }
      filter = SCContentFilter(
        display: display,
        excludingApplications: content.applications.filter {
          $0.processID == ProcessInfo.processInfo.processIdentifier
        }, exceptingWindows: [])
      sourceSize = CGSize(
        width: target.rectangle.width * Double(filter.pointPixelScale),
        height: target.rectangle.height * Double(filter.pointPixelScale))
      sourceRect = target.rectangle
    } else {
      throw RecordingError.message("请重新选择录屏范围。")
    }
    return CapturePlan(filter: filter, sourceSize: sourceSize, sourceRect: sourceRect)
  }
  private func resetPreparation() {
    session = nil
    task?.cancel()
    selection.cancel()
    closeQuickPanel()
    hud?.orderOut(nil)
    if let entry {
      let root = root
      Task.detached { try? RecordingFiles.delete(entry, root: root) }
    }
    entry = nil
    phase = .configuring
    changed()
  }
  func cancelPreparation() {
    guard [.selecting, .countdown, .authorizing].contains(phase) else { return }
    let wasQuick = quickEntry
    resetPreparation()
    quickEntry = false
    adjustmentOverride = false
    if !wasQuick { showSetup() }
  }
  func togglePause() {
    guard isRecording else { return }
    if phase == .recording {
      engine?.writer?.pause()
      phase = .paused
    } else {
      engine?.writer?.resume()
      phase = .recording
    }
    changed()
  }
  func finish(reason: String? = nil) async {
    guard isRecording, let engine, let entry else { return }
    phase = .finishing
    changed()
    removeObservers()
    timer?.invalidate()
    timer = nil
    do {
      let telemetry = try await engine.stop()
      try? await Task.detached {
        try JSONSerialization.data(
          withJSONObject: telemetry, options: [.sortedKeys, .prettyPrinted]
        ).write(to: entry.directory.appendingPathComponent("recording-info.json"), options: .atomic)
      }.value
      self.engine = nil
      let missingMic = options.microphone && (telemetry["microphoneBuffers"] as? Int ?? 0) == 0
      let overloaded = (telemetry["droppedBuffers"] as? Int ?? 0) > 0
      let warning =
        missingMic ? "没有收到麦克风音频，请检查设备后重试。" : (overloaded ? "系统繁忙，部分画面或声音可能缺失，请回放检查。" : nil)
      let completed = try await RecordingFiles.finish(entry)
      self.entry = nil
      session = nil
      phase = .completed
      hud?.orderOut(nil)
      self.error = reason ?? warning
      changed()
      await showResult(completed)
      refreshRecent()
    } catch {
      self.engine = nil
      self.entry = nil
      session = nil
      phase = .configuring
      hud?.orderOut(nil)
      self.error = "\(error.localizedDescription) 原片保留在最近录屏，可尝试重新导出。"
      changed()
      showSetup()
    }
  }
  func retry(_ entry: RecordingEntry) {
    guard !isBusy else { return }
    phase = .finishing
    error = nil
    changed()
    showHUD()
    Task {
      do {
        let completed = try await RecordingFiles.finish(entry)
        phase = .completed
        hud?.orderOut(nil)
        changed()
        await showResult(completed)
        refreshRecent()
      } catch {
        phase = .configuring
        hud?.orderOut(nil)
        self.error = error.localizedDescription
        changed()
        showSetup()
      }
    }
  }
  func showResult(_ entry: RecordingEntry) async {
    guard entry.completed else {
      retry(entry)
      return
    }
    do {
      let info = try await RecordingFiles.inspect(entry.url)
      result = entry
      resultInfo =
        "\(Self.timeLabel(info.duration)) · \(Int(info.size.width)) × \(Int(info.size.height)) · \(ByteCountFormatter.string(fromByteCount:info.bytes,countStyle:.file)) · \(entry.options.audioLabel)"
      resultWindow?.close()
      let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 760, height: 570),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
        defer: false)
      window.title = "录屏已完成"
      window.minSize = CGSize(width: 620, height: 480)
      window.isReleasedWhenClosed = false
      window.delegate = self
      window.contentView = NSHostingView(
        rootView: RecordingResultView(controller: self, entry: entry))
      window.center()
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      resultWindow = window
    } catch {
      self.error = error.localizedDescription
      showSetup()
    }
  }
  func saveResult(_ entry: RecordingEntry) {
    guard entry.completed, !fileBusy else { return }
    fileBusy = true
    let panel = NSSavePanel()
    savePanel = panel
    panel.allowedContentTypes = [.mpeg4Movie]
    panel.nameFieldStringValue =
      "录屏-\(entry.created.formatted(.iso8601.year().month().day().dateSeparator(.dash))).mp4"
    panel.title = "保存录屏"
    panel.begin { [weak self] response in
      guard let self else { return }
      self.savePanel = nil
      guard response == .OK, let url = panel.url else {
        self.fileBusy = false
        return
      }
      Task {
        do {
          try await Task.detached { try RecordingFiles.copy(entry.url, to: url) }.value
          self.error = nil
          NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { self.error = "保存失败：" + error.localizedDescription }
        self.fileBusy = false
      }
    }
  }
  func copyResult(_ entry: RecordingEntry, board: NSPasteboard = .general) {
    guard entry.completed, !fileBusy else { return }
    board.clearContents()
    if !board.writeObjects([entry.url as NSURL]) { error = "文件复制失败，请重试。" }
  }
  func delete(_ entry: RecordingEntry) {
    guard !isBusy, !fileBusy else { return }
    let alert = NSAlert()
    alert.messageText = "删除这段本地录屏？"
    alert.informativeText = "只删除Capture保存的作品，已另存到其他位置的副本会保留。"
    alert.addButton(withTitle: "删除")
    alert.addButton(withTitle: "取消")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let root = root
    Task {
      do {
        try await Task.detached { try RecordingFiles.delete(entry, root: root) }.value
        if result?.id == entry.id {
          resultWindow?.close()
          result = nil
        }
        refreshRecent()
      } catch { self.error = error.localizedDescription }
    }
  }
  func showHUD() {
    if let hud {
      hud.orderFrontRegardless()
      return
    }
    let panel = NSPanel(
      contentRect: CGRect(x: 0, y: 0, width: 510, height: 72),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isMovableByWindowBackground = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.contentView = NSHostingView(rootView: RecordingHUD(controller: self))
    panel.center()
    if let screen = NSScreen.main {
      panel.setFrameOrigin(
        CGPoint(x: screen.visibleFrame.midX - 255, y: screen.visibleFrame.minY + 26))
    }
    panel.orderFrontRegardless()
    hud = panel
  }
  private func beginTimer() {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.isRecording else { return }
        self.poll()
      }
    }
  }
  private var polling = false
  private var pollCount = 0
  private func poll() {
    guard !polling, let writer = engine?.writer else { return }
    polling = true
    let root = root
    let token = session
    pollCount += 1
    Task {
      defer { polling = false }
      let elapsed = await writer.elapsed()
      let free = await Task.detached { RecordingFiles.freeBytes(at: root) }.value
      guard session == token, isRecording else { return }
      seconds = elapsed
      changed()
      if let reason = RecordingLimits.stopReason(seconds: elapsed, freeBytes: free) {
        await finish(reason: reason)
        return
      }
      if pollCount % 4 == 0, let id = target?.windowID {
        do {
          let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
          if !content.windows.contains(where: { $0.windowID == id }), session == token, isRecording
          {
            await finish(reason: "目标窗口已关闭，录屏已停止。")
          }
        } catch {
          if session == token, isRecording {
            await finish(reason: "无法继续访问录制目标：" + error.localizedDescription)
          }
        }
      }
    }
  }
  private func installObservers() {
    removeObservers()
    workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
    ) { [weak self] _ in Task { @MainActor in await self?.finish(reason: "电脑即将睡眠，已停止录屏。") } }
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in Task { @MainActor in await self?.finish(reason: "显示器布局已变化，已停止录屏。") } }
    deviceObserver = NotificationCenter.default.addObserver(
      forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main
    ) { [weak self] notification in
      Task { @MainActor in
        guard let self, self.options.microphone,
          let device = notification.object as? AVCaptureDevice,
          self.options.microphoneID == nil || self.options.microphoneID == device.uniqueID
        else { return }
        await self.finish(reason: "麦克风已断开，已停止并保留录屏。")
      }
    }
    lockObserver = DistributedNotificationCenter.default().addObserver(
      forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
    ) { [weak self] _ in Task { @MainActor in await self?.finish(reason: "桌面已锁定，已停止录屏。") } }
  }
  private func removeObservers() {
    if let workspaceObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
    }
    if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    if let deviceObserver { NotificationCenter.default.removeObserver(deviceObserver) }
    if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
    workspaceObserver = nil
    screenObserver = nil
    deviceObserver = nil
    lockObserver = nil
  }
  func confirmTermination() async -> Bool {
    if phase == .starting {
      error = "录屏正在启动，请稍后停止再退出。"
      return false
    }
    if phase == .finishing {
      error = "录屏正在保存，请完成后再退出。"
      return false
    }
    if isRecording {
      let alert = NSAlert()
      alert.messageText = "停止录屏并退出Capture？"
      alert.informativeText = "将先完成本地保存。"
      alert.addButton(withTitle: "停止并退出")
      alert.addButton(withTitle: "取消")
      guard alert.runModal() == .alertFirstButtonReturn else { return false }
      await finish()
      return !isBusy
    }
    if isBusy { cancelPreparation() }
    return !fileBusy
  }
  func shutdown() {
    session = nil
    task?.cancel()
    timer?.invalidate()
    removeObservers()
    selection.cancel()
    closeQuickPanel()
    hud?.close()
    setupWindow?.close()
    resultWindow?.close()
    savePanel?.cancel(nil)
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool { sender !== setupWindow || !isBusy }
  func windowWillClose(_ notification: Notification) {
    if let window = notification.object as? NSWindow, window === setupWindow { setupWindow = nil }
    if let window = notification.object as? NSWindow, window === resultWindow { resultWindow = nil }
  }
}
