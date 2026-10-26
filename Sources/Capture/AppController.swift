import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CaptureCore
import Combine

enum CaptureMode { case area, window, fullScreen, previous, scrolling }
struct PreparedExport {
    let data: Data
    let format: ImageFormat
    let suggestedName: String
}

@MainActor
final class AppController: NSObject, ObservableObject, NSWindowDelegate {
    let store: AppStore
    let recording: RecordingController
    let loginItem = LoginItemController()
    let clipboard: NSPasteboard
    let library: LibraryStore
    var helpWindow: NSWindow?
    var collageWindow: NSWindow?
    @Published var busy = false
    @Published var copying = false
    @Published var saving = false
    @Published private(set) var pinning = false
    @Published private(set) var choosingFiles = false
    @Published private(set) var isScrolling = false
    @Published private(set) var scrollFrameCount = 0
    var activeSavePanel: NSSavePanel?
    private(set) var activeFilePanel: NSOpenPanel?
    @Published var lastDocument: CaptureDocument?
    @Published private(set) var recentDocuments: [CaptureDocument] = []
    @Published private(set) var canRepeatCapture = false
    private let pins = PinController()
    private let countdown = CountdownController()
    private let scrolling = ScrollingCaptureController()
    private var captureTask: Task<Void, Never>?
    private var captureSession: UUID?
    private var hiddenCaptureWindows: [NSWindow] = []
    @Published private(set) var countdownSeconds = 0
    private var recentWindow: NSWindow?
    private var presetsWindow: NSWindow?
    private var presetsTask: Task<Void, Never>?
    private var pinTask: Task<Void, Never>?
    private var previousSelection: ScreenSelection?
    private let hotKey = GlobalHotKey()
    private let recordingHotKey = GlobalHotKey()
    private let selection = SelectionController()
    private let thumbnail = ThumbnailController()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var editorWindows: [UUID: NSWindow] = [:]
    private var welcomeWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var sampleWindow: NSWindow?
    private var activationObserver: NSObjectProtocol?
    private var libraryObserver: AnyCancellable?
    private var started = false
    private var stopping = false
    @Published private(set) var recordingShortcut = false

    init(store: AppStore, clipboard: NSPasteboard = .general, libraryDirectory: URL? = nil, recordingDirectory: URL? = nil) {
        library = LibraryStore(directory: libraryDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Capture/Library"))
        self.store = store; self.clipboard = clipboard; recording = RecordingController(store: store, root: recordingDirectory); super.init()
        recording.canBegin = { [weak self] in self?.canStartCapture ?? false }
        recording.onChange = { [weak self] in self?.objectWillChange.send(); self?.updateStatus() }
        recording.onShortcut = { [weak self] in self?.setRecordingShortcut($0) }
        scrolling.$frames.assign(to: &$scrollFrameCount)
        libraryObserver = library.$error.sink { [weak store] error in
            if let error { store?.errorMessage = "本地历史：" + error }
            else if store?.errorMessage?.hasPrefix("本地历史：") == true { store?.errorMessage = nil }
        }
        applyInterfaceAppearance()
    }
    var canStartCapture: Bool { !busy && !recordingShortcut && !saving && !copying && !choosingFiles && !recording.isBusy && !recording.fileBusy && NSApp.modalWindow == nil }
    func start() {
        guard !started else { return }; started = true
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.target = self; button.action = #selector(togglePopover)
            button.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Capture")
            button.image?.isTemplate = true
        }
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuView(store: store, app: self))
        hotKey.onCapture = { [weak self] in
            guard let self else { return }
            if self.scrolling.isActive { self.finishScrollingCapture() }
            else if self.countdownSeconds > 0 { self.cancelCapture() }
            else { self.beginCapture() }
        }
        do { try hotKey.register(store.preferences.shortcut) }
        catch { store.shortcutError = error.localizedDescription }
        recordingHotKey.onCapture = { [weak self] in self?.popover.performClose(nil); self?.recording.hotkey() }
        do { try recordingHotKey.register(recording.options.shortcut) }
        catch { store.recordingShortcutError = error.localizedDescription }
        store.onChange = { [weak self] in self?.updateStatus() }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.store.refreshPermission()
                self?.loginItem.refresh()
            }
        }
        updateStatus()
        let firstLaunch = !store.preferences.hasLaunched
        if firstLaunch {
            store.update { $0.hasLaunched = true }
            showWelcome()
        }
    }
    func stop() {
        stopping = true
        recording.shutdown(); recordingHotKey.dispose()
        library.stop()
        collageWindow?.close(); helpWindow?.close()
        presetsTask?.cancel(); pinTask?.cancel()
        activeSavePanel?.cancel(nil); activeFilePanel?.cancel(nil)
        captureTask?.cancel(); scrolling.cancel(); countdown.dismiss(); selection.cancel(); thumbnail.dismiss(); pins.closeAll(); hotKey.dispose(); store.flush()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }
    private func updateStatus() {
        applyInterfaceAppearance()
        library.configure(store.preferences.localHistory ?? HistoryOptions())
        statusItem?.button?.title = recording.isBusy ? " " + recording.stateLabel + (recording.isRecording ? " " + recording.elapsedLabel : "") : ""
        statusItem?.button?.toolTip = store.preferences.automaticStyle
            ? "Capture · 默认预设：\(store.defaultName)\n区域截图 \(store.preferences.shortcut.display)"
            : "Capture · 普通截图\n区域截图 \(store.preferences.shortcut.display)"
    }
    private func applyInterfaceAppearance() {
        let theme = (store.preferences.presentation ?? PresentationOptions()).theme
        let desired: NSAppearance.Name? = theme == .system ? nil : (theme == .dark ? .darkAqua : .aqua)
        if NSApp.appearance?.name != desired { NSApp.appearance = desired.flatMap { NSAppearance(named: $0) } }
        if popover.appearance?.name != desired { popover.appearance = NSApp.appearance }
    }
    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            store.refreshPermission()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    @discardableResult
    func setShortcut(_ shortcut: Shortcut) -> String? {
        do {
            guard !shortcut.hasSameKeys(as: recording.options.shortcut) else { throw RecordingError.message("与录屏快捷键相同，请选择其他组合。") }
            try hotKey.register(shortcut)
            store.update { $0.shortcut = shortcut }; store.shortcutError = nil
            return nil
        } catch { store.shortcutError = error.localizedDescription; return error.localizedDescription }
    }
    func setShortcutRecording(_ active: Bool) {
        guard !stopping, active != recordingShortcut else { return }
        recordingShortcut = active
        if active {
            store.shortcutError = nil
            hotKey.suspend(); recordingHotKey.suspend()
        } else {
            do {
                try hotKey.resume()
                if !hotKey.isRegistered { try hotKey.register(store.preferences.shortcut) }
            }
            catch { store.shortcutError = "快捷键恢复失败：\(error.localizedDescription)" }
            do { try recordingHotKey.resume(); if !recordingHotKey.isRegistered { try recordingHotKey.register(recording.options.shortcut) } }
            catch { store.recordingShortcutError = "快捷键恢复失败：\(error.localizedDescription)" }
        }
    }
    @discardableResult
    func setRecordingShortcut(_ shortcut: Shortcut) -> String? {
        do {
            guard !shortcut.hasSameKeys(as: store.preferences.shortcut) else { throw RecordingError.message("与截图快捷键相同，请选择其他组合。") }
            try recordingHotKey.register(shortcut)
            recording.options.shortcut = shortcut; store.recordingShortcutError = nil; return nil
        } catch { store.recordingShortcutError = error.localizedDescription; return error.localizedDescription }
    }
    func showRecording() { popover.performClose(nil); guard canStartCapture || recording.isBusy else { return }; recording.isBusy ? recording.showActiveControls() : recording.beginQuick() }
    func showRecordingSettings() { popover.performClose(nil); guard canStartCapture || recording.isBusy else { return }; recording.showSetup() }
    func beginCapture(_ mode: CaptureMode = .area) {
        guard canStartCapture else { return }
        store.refreshPermission()
        guard store.permissionGranted else { popover.performClose(nil); showWelcome(); return }
        let session = UUID(); captureSession = session
        busy = true; popover.performClose(nil); thumbnail.dismiss()
        let style = store.captureStyle, automatic = store.preferences.automaticStyle
        let options = store.preferences.captureOptions ?? CaptureOptions()
        let mouseScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        hiddenCaptureWindows = NSApp.windows.filter { $0.isVisible }
        hiddenCaptureWindows.forEach { $0.orderOut(nil) }
        captureTask = Task { [self] in
          do {
            if mode == .fullScreen {
                guard let screen = mouseScreen, let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { finishCaptureUI(session); return }
                captureSelected(ScreenSelection(displayID: number.uint32Value, rectangle: CGRect(origin: .zero, size: screen.frame.size), scale: screen.backingScaleFactor, screen: screen), mode: mode, style: style, automatic: automatic, options: options, session: session)
            } else if mode == .previous {
                guard let previous = previousSelection, let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == previous.displayID }),
                      CGRect(origin: .zero, size: screen.frame.size).contains(previous.rectangle) else {
                    finishCaptureUI(session); presentError("上次区域已不可用，请重新框选。"); return
                }
                captureSelected(ScreenSelection(displayID: previous.displayID, rectangle: previous.rectangle, scale: screen.backingScaleFactor, screen: screen), mode: mode, style: style, automatic: automatic, options: options, session: session)
            } else {
                // Countdown precedes freezing for static selection. The user can prepare a hover state.
                if mode != .scrolling {
                    for remaining in (0..<options.delay).reversed() {
                        countdownSeconds = remaining + 1
                        countdown.show(seconds: remaining + 1, screen: mouseScreen) { [weak self] in self?.cancelCapture() }
                        try await Task.sleep(for: .seconds(1))
                    }
                    countdown.dismiss(); countdownSeconds = 0
                }
                let displays = NSScreen.screens.compactMap { screen -> (id: CGDirectDisplayID, scale: Double)? in
                    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
                    return (number.uint32Value, Double(screen.backingScaleFactor))
                }
                let frozen = try await ScreenCaptureService.freeze(displays: displays, includeCursor: options.includeCursor)
                let windows = mode == .scrolling ? [] : frozen.windows
                guard !Task.isCancelled, captureSession == session else { return }
                if mode == .window && windows.isEmpty { finishCaptureUI(session); presentError("没有找到可截图的窗口，请确认目标窗口已打开。"); return }
                let appearance = SelectionAppearance(style: style, enabled: automatic, name: store.defaultName)
                selection.begin(windows: windows, windowMode: mode == .window,
                                adjustable: options.allowsSelectionAdjustment, presets: store.presets, appearance: appearance,
                                confirmTitle: mode == .scrolling ? "开始长截图" : "复制截图", frames: frozen.frames) { [weak self] result in
                    guard let self, self.captureSession == session else { return }
                    guard let result else { self.finishCaptureUI(session); return }
                    self.captureSelected(result, mode: mode, style: style, automatic: automatic, options: options, session: session)
                }
            }
          } catch is CancellationError { }
          catch {
              guard captureSession == session else { return }
              finishCaptureUI(session); store.refreshPermission()
              if !store.permissionGranted { showWelcome() } else { presentError(error.localizedDescription) }
          }
        }
    }
    private func captureSelected(_ result: ScreenSelection, mode: CaptureMode, style: CaptureStyle, automatic: Bool, options: CaptureOptions, session: UUID) {
        guard captureSession == session else { return }
        let style = result.appearance?.style ?? style
        let automatic = result.appearance?.enabled ?? automatic
        captureTask = Task { [self] in
            defer { if !scrolling.isActive { finishCaptureUI(session) } }
            do {
                for remaining in (0..<(result.frozenFrame != nil && mode != .scrolling ? 0 : options.delay)).reversed() {
                    countdownSeconds = remaining + 1
                    countdown.show(seconds: remaining + 1, screen: result.screen) { [weak self] in self?.cancelCapture() }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                countdown.dismiss(); countdownSeconds = 0
                try Task.checkCancellation()
                guard captureSession == session else { return }
                if mode == .scrolling {
                    isScrolling = true
                    scrolling.begin(selection: result.withoutFrame, includeCursor: options.includeCursor) { [weak self] image in
                        guard let self, self.captureSession == session else { return }
                        guard let image else { self.finishCaptureUI(session); return }
                        self.captureTask = Task {
                            defer { self.finishCaptureUI(session) }
                            self.previousSelection = result.withoutFrame; self.canRepeatCapture = true
                            let document = self.makeDocument(image, style: style, enabled: automatic)
                            self.remember(document)
                            await self.copy(document, on: result.screen, showThumbnail: true)
                        }
                    }
                    return
                }
                let image: CGImage
                if let frame = result.frozenFrame {
                    let rect = result.rectangle
                    image = try await Task.detached(priority: .userInitiated) { try frame.cropped(to: rect) }.value
                } else if let id = result.windowID {
                    image = try await ScreenCaptureService.captureWindow(id: id, size: result.rectangle.size, scale: result.scale, includeCursor: options.includeCursor)
                } else {
                    image = try await ScreenCaptureService.capture(displayID: result.displayID, selection: result.rectangle, backingScale: result.scale, includeCursor: options.includeCursor)
                }
                try Task.checkCancellation()
                guard captureSession == session else { return }
                if (result.windowID == nil || result.frozenFrame != nil) && mode != .fullScreen { previousSelection = result.withoutFrame; canRepeatCapture = true }
                let document = makeDocument(image, style: style, enabled: automatic)
                remember(document)
                await copy(document, on: result.screen, showThumbnail: true)
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, captureSession == session else { return }
                store.refreshPermission()
                if !store.permissionGranted { showWelcome() } else { presentError(error.localizedDescription) }
            }
        }
    }
    func cancelCapture() {
        guard let session = captureSession else { return }
        captureTask?.cancel(); countdown.dismiss(); selection.cancel(); scrolling.cancel(); finishCaptureUI(session)
    }
    func finishScrollingCapture() {
        guard isScrolling, scrollFrameCount > 0 else { return }
        scrolling.finish()
    }
    private func finishCaptureUI(_ session: UUID) {
        guard captureSession == session else { return }
        captureSession = nil
        busy = false; isScrolling = false; countdownSeconds = 0; countdown.dismiss()
        if !stopping { hiddenCaptureWindows.forEach { $0.orderFront(nil) } }
        hiddenCaptureWindows.removeAll()
    }
    private func makeDocument(_ image: CGImage, style: CaptureStyle, enabled: Bool, sample: Bool = false) -> CaptureDocument {
        let document = CaptureDocument(image: image, style: style, useStyle: enabled, isSample: sample)
        document.onStyleChange = { [weak store] style in store?.useStyle(style) }
        return document
    }
    func copy(_ document: CaptureDocument, originalOnly: Bool = false, on screen: NSScreen? = nil, showThumbnail: Bool = false) async {
        guard !copying else { return }
        copying = true
        defer { copying = false }
        do {
            let raw = originalOnly
            let copiedStyle = document.style
            let copiedWithStyle = document.useStyle
            let image = try await document.rendered(originalOnly: originalOnly)
            try Task.checkCancellation()
            try ClipboardService.write(image, to: clipboard)
            document.copiedImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            let styleName = store.presets.first(where: { $0.style == copiedStyle })?.name ?? "自定义"
            document.copyLabel = raw ? "已复制 · 原始截图" : (copiedWithStyle ? "已复制 · \(styleName)" : "已复制 · 截图")
            document.copiedDimensions = "\(image.width) × \(image.height)"
            document.message = raw ? "原始截图已复制" : "当前图片已复制"
            trimRecent()
        } catch is CancellationError { return }
        catch {
            document.message = "复制失败：" + error.localizedDescription
            if showThumbnail { showEditor(document) }
            presentError(document.message ?? error.localizedDescription)
            return
        }
        if showThumbnail && store.preferences.showThumbnail { thumbnail.show(document: document, screen: screen, app: self) }
    }
    func save(_ document: CaptureDocument, originalOnly: Bool = false) {
        guard !saving, !recording.isBusy, !recording.fileBusy else { return }
        saving = true; thumbnail.pause()
        Task {
            defer { saving = false; activeSavePanel = nil; thumbnail.resume() }
            do {
                let output = try await prepareExport(document, originalOnly: originalOnly)
                let panel = NSSavePanel()
                activeSavePanel = panel
                panel.title = originalOnly ? "保存原图" : "保存截图"
                panel.canCreateDirectories = true
                panel.allowedContentTypes = [output.format == .png ? .png : .jpeg]
                panel.nameFieldStringValue = output.suggestedName
                if let path = store.preferences.saveDirectory { panel.directoryURL = URL(fileURLWithPath: path) }
                NSApp.activate(ignoringOtherApps: true)
                guard await panel.begin() == .OK, let url = panel.url else { return }
                try await writeExport(output, to: url, document: document)
                thumbnail.dismiss()
            } catch { document.message = error.localizedDescription; presentError(error.localizedDescription) }
        }
    }
    func prepareExport(_ document: CaptureDocument, originalOnly: Bool = false) async throws -> PreparedExport {
        let format = originalOnly ? ImageFormat.png : document.outputFormat
        let quality = document.jpegQuality
        let name = document.filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = (name.isEmpty ? "Screenshot" : name.replacingOccurrences(of: "/", with: "-")) + (originalOnly ? "-original" : "") + "." + format.fileExtension
        let image = try await document.rendered(originalOnly: originalOnly, scale: originalOnly ? 1 : document.outputScale, opaque: format == .jpeg)
        let data = try await Task.detached(priority: .userInitiated) { try StyleCompositor.encode(image, format: format, quality: quality) }.value
        return PreparedExport(data: data, format: format, suggestedName: filename)
    }
    func writeExport(_ output: PreparedExport, to url: URL, document: CaptureDocument) async throws {
        let data = output.data
        try await Task.detached(priority: .utility) { try data.write(to: url, options: .atomic) }.value
        store.update { $0.saveDirectory = url.deletingLastPathComponent().path }
        document.message = "已保存 \(url.lastPathComponent)"
    }
    func restoreThumbnail() {
        if let lastDocument { thumbnail.show(document: lastDocument, screen: NSScreen.main, app: self) }
    }
    func restorePins() { pins.restoreInteraction() }
    func closePins() { pins.closeAll() }
    func existingDocument(_ id: UUID) -> CaptureDocument? {
        (editorWindows[id] as? CaptureEditorWindow)?.captureDocument ?? recentDocuments.first { $0.id == id }
    }
    func showLastDocument() { if let lastDocument { showEditor(lastDocument) } }
    func remember(_ document: CaptureDocument) {
        document.onContentChange = { [weak self, weak document] in
            guard let self, let document else { return }; self.library.schedule(document); self.objectWillChange.send()
        }
        library.schedule(document)
        lastDocument = document
        recentDocuments.removeAll { $0.id == document.id }; recentDocuments.insert(document, at: 0)
        trimRecent()
    }
    private func trimRecent() {
        while recentDocuments.count > 12 || (recentDocuments.count > 1 && recentDocuments.reduce(0, { $0 + $1.estimatedMemoryBytes }) > 160_000_000) {
            recentDocuments.removeLast()
        }
    }
    func clearRecent() { recentDocuments.removeAll(); lastDocument = nil }
    func removeRecent(_ document: CaptureDocument) {
        recentDocuments.removeAll { $0.id == document.id }
        if lastDocument?.id == document.id { lastDocument = recentDocuments.first }
    }
    func showRecent() {
        popover.performClose(nil)
        if let recentWindow { recentWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 740, height: 550), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        library.reload()
        window.title = "截图库"; window.isReleasedWhenClosed = false; window.minSize = CGSize(width: 660, height: 420)
        window.contentView = NSHostingView(rootView: RecentCapturesView(app: self))
        recentWindow = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func pin(_ document: CaptureDocument) {
        guard !pinning else { return }
        popover.performClose(nil)
        pinning = true
        pinTask = Task {
            defer { pinning = false }
            do {
                let image = try await document.rendered()
                try Task.checkCancellation()
                guard !stopping else { return }
                if pins.show(image, document: document, app: self) { thumbnail.dismiss() }
                else { presentError("最多同时置顶 8 张图片，请先关闭一张。") }
            }
            catch is CancellationError {}
            catch { if !Task.isCancelled { presentError(error.localizedDescription) } }
        }
    }
    @discardableResult
    func copyPinnedImage(_ image: CGImage) -> Bool {
        do { try ClipboardService.write(image, to: clipboard); return true }
        catch { presentError(error.localizedDescription); return false }
    }
    func recognize(_ document: CaptureDocument) { showEditor(document); document.showingRecognition = true }
    func importClipboard() {
        popover.performClose(nil)
        let board = clipboard
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let url = urls.first {
            openImage(url: url); return
        }
        guard let data = board.data(forType: .png) ?? board.data(forType: .tiff) else {
            presentError("剪贴板里没有图片。请先复制一张图片，再试一次。"); return
        }
        importImageData(data)
    }
    func beginFileChoice(_ panel: NSOpenPanel) -> Bool {
        guard !choosingFiles, !saving, !busy, !recording.isBusy, !recording.fileBusy else { return false }
        choosingFiles = true; activeFilePanel = panel; popover.performClose(nil)
        return true
    }
    func endFileChoice() { choosingFiles = false; activeFilePanel = nil }
    func combineImages() {
        guard !choosingFiles, !saving, !busy, !recording.isBusy, !recording.fileBusy else { return }
        popover.performClose(nil)
        choosingFiles = true
        let panel = NSOpenPanel(); panel.title = "选择 2–12 张图片，在拼图工作台调整"
        activeFilePanel = panel
        panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            self?.choosingFiles = false
            self?.activeFilePanel = nil
            guard response == .OK, let self else { return }
            let urls = panel.urls
            guard (2...12).contains(urls.count) else { self.presentError("请选择 2–12 张图片。"); return }
            Task {
                do {
                    let images = try await Task.detached(priority: .userInitiated) { try CollageLayout.loadImages(urls) }.value
                    self.showCollage(images: images, names: urls.map { $0.deletingPathExtension().lastPathComponent })
                } catch { self.presentError(error.localizedDescription) }
            }
        }
    }
    func importDroppedImage(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { [weak self] data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else { return }
                Task { @MainActor in self?.openImage(url: url) }
            }
            return true
        }
        if let type = [UTType.png.identifier, UTType.tiff.identifier].first(where: { provider.hasItemConformingToTypeIdentifier($0) }) {
            provider.loadDataRepresentation(forTypeIdentifier: type) { [weak self] data, _ in
                guard let data else { return }
                Task { @MainActor in self?.importImageData(data) }
            }
            return true
        }
        return false
    }
    private func importImageData(_ data: Data) {
        Task {
            do {
                let image = try await Task.detached(priority: .userInitiated) { try StyleCompositor.decode(data) }.value
                let document = makeDocument(image, style: store.captureStyle, enabled: store.preferences.automaticStyle)
                remember(document); showEditor(document)
            } catch { presentError(error.localizedDescription) }
        }
    }
    func showStyleEditor(style: CaptureStyle? = nil) {
        let document = makeDocument(SampleImage.make(), style: style ?? store.captureStyle, enabled: true, sample: true)
        showEditor(document)
    }
    func showPresets(document: CaptureDocument? = nil) {
        popover.performClose(nil)
        presetsTask?.cancel()
        presetsTask = Task {
            do {
                let source: CGImage
                if let document { source = try await document.rendered(contentOnly: true) } else { source = SampleImage.make() }
                try Task.checkCancellation()
                guard !stopping else { return }
                let window = presetsWindow ?? NSWindow(contentRect: CGRect(x: 0, y: 0, width: 920, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                if presetsWindow == nil { window.center() }
                window.title = "样式预设"; window.isReleasedWhenClosed = false; window.minSize = CGSize(width: 820, height: 570)
                window.contentView = NSHostingView(rootView: PresetsView(store: store, app: self, source: source, document: document))
                presetsWindow = window; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            } catch is CancellationError {}
            catch { if !Task.isCancelled { presentError(error.localizedDescription) } }
        }
    }
    func showEditor(_ document: CaptureDocument) {
        popover.performClose(nil); thumbnail.dismiss()
        if let window = editorWindows[document.id] {
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let window = CaptureEditorWindow(contentRect: CGRect(x: 0, y: 0, width: 1120, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = document.isSample ? "Capture · 样式预览" : "Capture · 截图美化"
        window.captureDocument = document; window.captureApp = self
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.delegate = self
        window.minSize = NSSize(width: 900, height: 640)
        window.contentView = NSHostingView(rootView: EditorView(document: document, store: store, app: self))
        window.setFrameAutosaveName("CaptureEditor")
        if !window.setFrameUsingName("CaptureEditor") { window.center() }
        editorWindows[document.id] = window
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func promptSavePreset(_ document: CaptureDocument) {
        let alert = NSAlert()
        alert.messageText = "保存分享样式"
        alert.informativeText = "保存背景、布局、窗口配色和效果。标注与遮挡不会存入样式预设。"
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        var suggested = "我的分享样式", suffix = 2
        while store.presets.contains(where: { $0.name == suggested }) { suggested = "我的分享样式 \(suffix)"; suffix += 1 }
        let field = CapturePanelField(input: suggested)
        field.frame = CGRect(x: 0, y: 30, width: 280, height: 24); field.placeholderString = "预设名称"
        let makeDefault = NSButton(checkboxWithTitle: "同时设为截图默认", target: nil, action: nil)
        makeDefault.frame = CGRect(x: 0, y: 0, width: 280, height: 22)
        let accessory = NSView(frame: CGRect(x: 0, y: 0, width: 280, height: 58)); accessory.addSubview(field); accessory.addSubview(makeDefault)
        alert.accessoryView = accessory; alert.window.initialFirstResponder = field
        while alert.runModal() == .alertFirstButtonReturn {
            if store.savePreset(name: field.stringValue, style: document.style, makeDefault: makeDefault.state == .on) != nil {
                document.message = "已保存预设「\(String(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)))」" + (makeDefault.state == .on ? "，已设为截图默认" : "")
                return
            }
            alert.alertStyle = .warning
            alert.informativeText = store.errorMessage ?? "无法保存预设，请检查名称。"
        }
    }
    func openImage(url: URL? = nil) {
        popover.performClose(nil)
        if let url { if url.pathExtension.lowercased() == "capture" { openProject(url) } else { loadImage(url) }; return }
        guard !choosingFiles, !saving, !busy, !recording.isBusy, !recording.fileBusy else { return }
        choosingFiles = true
        let panel = NSOpenPanel()
        activeFilePanel = panel
        panel.title = "打开图片或 Capture 项目"; panel.allowedContentTypes = [.image, UTType(filenameExtension: "capture") ?? .data]; panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            self?.choosingFiles = false
            self?.activeFilePanel = nil
            if response == .OK, let url = panel.url { self?.openImage(url: url) }
        }
    }
    private func loadImage(_ url: URL) {
        Task {
            do {
                let image = try await Task.detached(priority: .userInitiated) { try StyleCompositor.decode(url) }.value
                let document = makeDocument(image, style: store.captureStyle, enabled: store.preferences.automaticStyle)
                document.filename = url.deletingPathExtension().lastPathComponent + "-styled"
                remember(document)
                showEditor(document)
            } catch { presentError(error.localizedDescription) }
        }
    }
    func showWelcome() {
        popover.performClose(nil)
        store.refreshPermission()
        if let welcomeWindow { welcomeWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 530, height: 540),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "欢迎使用 Capture"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WelcomeView(store: store, app: self))
        welcomeWindow = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func showSettings() {
        popover.performClose(nil)
        loginItem.refresh()
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 530),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.styleMask.insert(.resizable); window.minSize = CGSize(width: 520, height: 450)
        window.setContentSize(CGSize(width: 580, height: 720))
        window.title = "Capture 设置"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(store: store, app: self))
        settingsWindow = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func captureTestWindow() {
        guard canStartCapture else { return }
        store.refreshPermission()
        guard store.permissionGranted else { showWelcome(); return }
        busy = true
        let session = UUID(); captureSession = session
        let image = SampleImage.make()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 450),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Capture 测试图"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Image(nsImage: NSImage(cgImage: image, size: CGSize(width: 1440, height: 900))).resizable().scaledToFit())
        sampleWindow = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let style = store.captureStyle, enabled = store.preferences.automaticStyle
        captureTask = Task {
            defer {
                window.orderOut(nil); window.close()
                if sampleWindow === window { sampleWindow = nil }
                finishCaptureUI(session)
            }
            do {
                try await Task.sleep(nanoseconds: 450_000_000)
                let result = try await ScreenCaptureService.captureSample(windowID: CGWindowID(window.windowNumber), size: window.frame.size, scale: Double(window.screen?.backingScaleFactor ?? 2))
                try Task.checkCancellation()
                guard captureSession == session else { return }
                let document = makeDocument(result, style: style, enabled: enabled, sample: true)
                remember(document)
                await copy(document, on: window.screen, showThumbnail: true)
            } catch is CancellationError { }
            catch { if !Task.isCancelled && captureSession == session { presentError(error.localizedDescription) } }
        }
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let key = editorWindows.first(where: { $0.value === window })?.key else { return }
        editorWindows.removeValue(forKey: key)
    }
    private func presentError(_ message: String) {
        let alert = NSAlert(); alert.messageText = "Capture"; alert.informativeText = message
        alert.addButton(withTitle: "好"); NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
    func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 Capture", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "设置…", action: #selector(settingsAction), keyEquivalent: ","); settings.target = self; appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Capture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; main.addItem(appItem)
        let file = NSMenuItem(); let fileMenu = NSMenu(title: "文件")
        for (title, action, key) in [("新截图", #selector(captureAction), "n"), ("录制屏幕…", #selector(recordScreenAction), ""), ("打开图片或项目…", #selector(openImageAction), "o"),
                                     ("从剪贴板打开", #selector(clipboardAction), ""), ("最近截图…", #selector(recentAction), ""),
                                     ("拼接多张图片…", #selector(combineAction), "")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; fileMenu.addItem(item)
        }
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "保存截图…", action: #selector(CaptureEditorWindow.saveDocument(_:)), keyEquivalent: "s")
        let projectItem = fileMenu.addItem(withTitle: "保存可编辑项目…", action: #selector(CaptureEditorWindow.saveProject(_:)), keyEquivalent: "s"); projectItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.submenu = fileMenu; main.addItem(file)
        let edit = NSMenuItem(); let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("重做", "redo:", "Z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            let item = editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key == "Z" ? "z" : key)
            if key == "Z" { item.keyEquivalentModifierMask = [.command, .shift] }
        }
        edit.submenu = editMenu; main.addItem(edit)
        let helpItem = NSMenuItem(), help = NSMenu(title: "帮助")
        let guide = help.addItem(withTitle: "Capture 使用指南", action: #selector(helpAction), keyEquivalent: "?"); guide.target = self
        helpItem.submenu = help; main.addItem(helpItem); NSApp.mainMenu = main
    }
    @objc private func helpAction() { showHelp() }
    @objc private func settingsAction() { showSettings() }
    @objc private func recordScreenAction() { showRecording() }
    @objc private func captureAction() { beginCapture() }
    @objc private func openImageAction() { openImage() }
    @objc private func clipboardAction() { importClipboard() }
    @objc private func recentAction() { showRecent() }
    @objc private func combineAction() { combineImages() }
}
