import AppKit
import CaptureCore

struct SelectionAppearance: Equatable {
    var style: CaptureStyle
    var enabled: Bool
    var name: String
}

struct ScreenSelection {
    let displayID: CGDirectDisplayID
    let rectangle: CGRect
    let scale: Double
    let screen: NSScreen
    var windowID: CGWindowID? = nil
    var appearance: SelectionAppearance? = nil
    var frozenFrame: FrozenFrame? = nil
    var withoutFrame: ScreenSelection { var copy = self; copy.frozenFrame = nil; return copy }
}

@MainActor
final class SelectionController {
    private var panels: [NSPanel] = []
    private var activeRecordingPanel: NSPanel?
    private var completion: ((ScreenSelection?) -> Void)?
    private var displayObserver: NSObjectProtocol?
    var isSelecting: Bool { !panels.isEmpty }

    func begin(windows: [CaptureWindow] = [], windowMode: Bool = false, adjustable: Bool = false,
               presets: [StylePreset] = [], appearance: SelectionAppearance? = nil, confirmTitle: String = "复制截图",
               frames: [CGDirectDisplayID: FrozenFrame] = [:], recording: Bool = false,
               externalRecordingControls: Bool = false, initialSelection: ScreenSelection? = nil,
               onGeometryChange: ((NSScreen, CGRect, Bool, Bool, Bool) -> Void)? = nil,
               onRecordingModeChange: ((Bool) -> Void)? = nil,
               completion: @escaping (ScreenSelection?) -> Void) {
        guard !isSelecting else { return }
        self.completion = completion
        if !frames.isEmpty && NSScreen.screens.contains(where: { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let frame = frames[id.uint32Value] else { return true }
            return frame.pointSize != screen.frame.size
        }) { finish(nil); return }
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.finish(nil) } }
        for screen in NSScreen.screens {
            let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.setFrame(screen.frame, display: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.level = .screenSaver; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.acceptsMouseMovedEvents = true
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.scale = screen.backingScaleFactor
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                view.frozenFrame = frames[number.uint32Value]
            }
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
            view.windows = windows.map { window in
                CaptureWindow(id: window.id, title: window.title, frame: CGRect(x: window.frame.minX - screen.frame.minX,
                    y: window.frame.minY + screen.frame.maxY - primaryTop, width: window.frame.width, height: window.frame.height))
            }
            view.windowMode = windowMode; view.adjustable = adjustable; view.recordingSelection = recording; view.externalRecordingControls = externalRecordingControls
            view.onGeometryChange = { [weak screen] rect, ready, dragging, windowMode in
                guard let screen else { return }; onGeometryChange?(screen,rect,ready,dragging,windowMode)
            }
            view.configureStyles(presets: presets, appearance: appearance, confirmTitle: confirmTitle)
            view.onActivate = { [weak self, weak view] in
                self?.activeRecordingPanel = view?.window as? NSPanel
                self?.views.filter { $0 !== view }.forEach { $0.resetSelection() }
            }
            view.onToggleWindowMode = { [weak self] mode in
                self?.views.forEach { $0.windowMode = mode; $0.resetSelection() }; onRecordingModeChange?(mode)
            }
            view.onAppearanceChange = { [weak self] appearance in self?.views.forEach { $0.setAppearance(appearance) } }
            // Native menus use a lower window level than the screen overlay. Lower
            // only while tracking so the menu remains visible, including submenus.
            view.onMenuTracking = { [weak self] tracking in self?.panels.forEach { $0.level = tracking ? .statusBar : .screenSaver } }
            view.onWindow = { [weak self, weak screen, weak view] window in
                guard let screen, let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { self?.finish(nil); return }
                self?.finish(ScreenSelection(displayID: number.uint32Value, rectangle: window.frame, scale: screen.backingScaleFactor,
                                             screen: screen, windowID: window.id, appearance: view?.outputAppearance, frozenFrame: frames[number.uint32Value]))
            }
            view.onFinish = { [weak self, weak screen, weak view] rect in
                guard let screen, let rect,
                      let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { self?.finish(nil); return }
                self?.finish(ScreenSelection(displayID: number.uint32Value, rectangle: rect, scale: screen.backingScaleFactor,
                                             screen: screen, appearance: view?.outputAppearance, frozenFrame: frames[number.uint32Value]))
            }
            panel.contentView = view; panels.append(panel); panel.orderFrontRegardless()
            if let initialSelection, initialSelection.displayID == (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value {
                view.restoreRecordingSelection(initialSelection.rectangle,windowID:initialSelection.windowID)
            }
        }
        let screenAtMouse = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        let active = panels.first { $0.screen == initialSelection?.screen } ?? panels.first { $0.screen == screenAtMouse } ?? panels.first
        activeRecordingPanel = active
        active?.makeKey()
        if let view = active?.contentView { active?.makeFirstResponder(view); (view as? SelectionView)?.publishGeometry() }
        if panels.isEmpty { finish(nil) }
    }
    private var views: [SelectionView] { panels.compactMap { $0.contentView as? SelectionView } }
    func cancel() { finish(nil) }
    func updateRecordingAdjustment(_ enabled: Bool) { views.forEach { $0.adjustable = enabled } }
    func updateRecordingMode(window: Bool) {
        views.forEach { $0.windowMode = window; $0.resetSelection() }; activateRecordingSelection()
    }
    func activateRecordingSelection() {
        let active = activeRecordingPanel ?? panels.first(where: { $0.isKeyWindow }) ?? panels.first
        active?.makeKey(); if let view=active?.contentView as? SelectionView { active?.makeFirstResponder(view); view.publishGeometry() }
    }
    func selectRecordingDisplay(_ screen: NSScreen) {
        for view in views {
            if view.window?.screen == screen { activeRecordingPanel = view.window as? NSPanel; view.windowMode = false; view.restoreRecordingSelection(view.bounds,windowID:nil); view.window?.makeKey(); view.window?.makeFirstResponder(view) }
            else { view.resetSelection() }
        }
        activateRecordingSelection()
    }
    func confirmRecordingSelection() { views.first(where: { $0.ready })?.confirmSelection() }
    func setRecordingMenuTracking(_ tracking: Bool) { panels.forEach { $0.level = tracking ? .statusBar : .screenSaver }; if !tracking { activateRecordingSelection() } }
    private func finish(_ result: ScreenSelection?) {
        guard completion != nil else { return }
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver); self.displayObserver = nil }
        let callback = completion; completion = nil
        for panel in panels { (panel.contentView as? SelectionView)?.stopStylePreview(); panel.orderOut(nil); panel.close() }
        panels.removeAll(); activeRecordingPanel = nil; callback?(result)
    }
}

final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class SelectionView: NSView, NSMenuDelegate {
    var frozenFrame: FrozenFrame? {
        didSet { frozenImage = frozenFrame.map { NSImage(cgImage: $0.image, size: $0.pointSize) }; needsDisplay = true }
    }
    private var frozenImage: NSImage?
    var scale = 1.0
    var windows: [CaptureWindow] = []
    var windowMode = false
    var adjustable = false
    var recordingSelection = false
    var externalRecordingControls = false
    var onGeometryChange: ((CGRect, Bool, Bool, Bool) -> Void)?
    func publishGeometry(dragging: Bool = false) { onGeometryChange?(rectangle, ready, dragging, windowMode) }
    func restoreRecordingSelection(_ rect: CGRect, windowID: CGWindowID?) {
        guard !rect.isEmpty, bounds.contains(rect) else { return }
        selectedWindow = windowID.flatMap { id in windows.first { $0.id == id } }
        rectangle = selectedWindow?.frame.intersection(bounds) ?? rect; ready = true; refresh()
    }
    var onActivate: (() -> Void)?
    var onToggleWindowMode: ((Bool) -> Void)?
    var onAppearanceChange: ((SelectionAppearance) -> Void)?
    var onMenuTracking: ((Bool) -> Void)?
    var onWindow: ((CaptureWindow) -> Void)?
    var onFinish: ((CGRect?) -> Void)?
    private(set) var outputAppearance: SelectionAppearance?
    private(set) var rectangle = CGRect.zero
    private(set) var ready = false
    private var hoveredWindow: CaptureWindow?
    private var selectedWindow: CaptureWindow?
    private var presets: [StylePreset] = []
    private var initialAppearance: SelectionAppearance?
    private(set) var styleInspectorOpen = false
    private var previewTask: Task<Void, Never>?
    private var previewRevision = 0
    private var previewRequest: PreviewRequest?
    private struct PreviewRequest: Equatable { let rectangle: CGRect; let appearance: SelectionAppearance }
    private var gesture: Gesture?
    private enum Gesture {
        case create(CGPoint)
        case move(CGRect, CGPoint)
        case resize(CGRect, CGPoint, SelectionHandle)
    }
    private(set) lazy var toolbar: SelectionToolbar = {
        let toolbar = SelectionToolbar()
        toolbar.isHidden = true
        toolbar.confirm.target = self; toolbar.confirm.action = #selector(confirmSelection)
        toolbar.redraw.target = self; toolbar.redraw.action = #selector(redrawSelection)
        toolbar.cancel.target = self; toolbar.cancel.action = #selector(cancelSelection)
        toolbar.customize.target = self; toolbar.customize.action = #selector(toggleStyleInspector)
        toolbar.inspector.onChange = { [weak self] appearance in
            guard let self else { return }; self.setAppearance(appearance); self.onAppearanceChange?(appearance)
        }
        toolbar.inspector.onReset = { [weak self] in
            guard let self, let initial = self.initialAppearance else { return }
            self.setAppearance(initial); self.onAppearanceChange?(initial)
        }
        toolbar.inspector.onClose = { [weak self] in self?.closeStyleInspector(discardInvalidInput: true) }
        toolbar.inspector.frameStyle.menu?.delegate = self
        toolbar.inspector.ratio.menu?.delegate = self
        addSubview(toolbar)
        return toolbar
    }()
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configureStyles(presets: [StylePreset], appearance: SelectionAppearance?, confirmTitle: String) {
        self.presets = presets; self.outputAppearance = appearance; initialAppearance = appearance
        guard adjustable else { return }
        toolbar.confirm.title = confirmTitle + " ↩"
        let menu = NSMenu(title: "本次截图样式"); menu.delegate = self
        let title = NSMenuItem(title: "本次截图样式 · 不改变默认", action: nil, keyEquivalent: ""); title.isEnabled = false; menu.addItem(title)
        let plain = styleItem("普通截图（不美化）", tag: -1)
        plain.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil); menu.addItem(plain)
        let custom = styleItem("自定义样式…", tag: -2)
        custom.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil); menu.addItem(custom)
        // Draw tiny swatches instead of synchronously compositing up to 100 full styled images.
        for builtIn in [true, false] {
            let entries = presets.enumerated().filter { $0.element.isBuiltIn == builtIn }
            guard !entries.isEmpty else { continue }
            menu.addItem(.separator())
            let heading = NSMenuItem(title: builtIn ? "内置预设" : "我的预设", action: nil, keyEquivalent: ""); heading.isEnabled = false; menu.addItem(heading)
            for (index, preset) in entries {
                let item = styleItem(preset.name, tag: index)
                item.image = SelectionToolbar.swatch(preset.style)
                menu.addItem(item)
            }
        }
        toolbar.styles.menu = menu
        if recordingSelection { toolbar.styles.isHidden = true; toolbar.customize.isHidden = true; toolbar.recordingNote.isHidden = false }
        refresh()
    }
    private func styleItem(_ title: String, tag: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(selectAppearance(_:)), keyEquivalent: "")
        item.tag = tag; item.target = self; return item
    }
    @objc private func selectAppearance(_ sender: NSMenuItem) {
        if sender.tag == -2 { openStyleInspector(); return }
        guard var next = outputAppearance ?? initialAppearance else { return }
        if sender.tag == -1 { next.enabled = false }
        else if presets.indices.contains(sender.tag) {
            let preset = presets[sender.tag]; next = SelectionAppearance(style: preset.style, enabled: true, name: preset.name)
        } else { return }
        setAppearance(next); onAppearanceChange?(next); window?.makeFirstResponder(self)
    }
    func setAppearance(_ appearance: SelectionAppearance) {
        guard appearance.style.isValid else { return }
        self.outputAppearance = appearance; toolbar.inspector.apply(appearance); refresh()
    }
    @objc private func toggleStyleInspector() {
        if styleInspectorOpen { closeStyleInspector() } else { openStyleInspector() }
    }
    private func openStyleInspector() {
        guard ready else { return }
        styleInspectorOpen = true
        toolbar.inspector.apply(outputAppearance ?? SelectionAppearance(style: CaptureStyle(), enabled: false, name: "自定义"))
        refresh(); window?.makeFirstResponder(self)
    }
    private func closeStyleInspector(discardInvalidInput: Bool = false) {
        guard styleInspectorOpen else { return }
        if !discardInvalidInput && !toolbar.inspector.commitColors(notify: true) { NSSound.beep(); return }
        if let outputAppearance { toolbar.inspector.apply(outputAppearance) }
        styleInspectorOpen = false; stopStylePreview(); refresh(); window?.makeFirstResponder(self)
    }
    func stopStylePreview() { previewTask?.cancel(); previewTask = nil; previewRequest = nil; previewRevision += 1 }
    private func requestStylePreview() {
        guard styleInspectorOpen, ready, let appearance = outputAppearance else { return }
        let request = PreviewRequest(rectangle: rectangle, appearance: appearance)
        guard request != previewRequest else { return }
        stopStylePreview(); previewRequest = request
        let revision = previewRevision, frame = frozenFrame
        toolbar.inspector.showPreviewStatus(frame == nil ? "此模式无冻结预览，确认后按原图输出" : "正在更新…")
        guard let frame else { return }
        previewTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 65_000_000)
                let worker = Task.detached(priority: .userInitiated) {
                    let crop = try frame.cropped(to: request.rectangle)
                    try Task.checkCancellation()
                    return try StyleCompositor.render(crop, style: appearance.enabled ? appearance.style : nil, previewLimit: 820)
                }
                let image = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, let self, self.styleInspectorOpen, self.previewRevision == revision else { return }
                self.toolbar.inspector.showPreview(image)
            } catch {
                guard !Task.isCancelled, let self, self.previewRevision == revision else { return }
                self.toolbar.inspector.showPreviewStatus("预览失败：" + error.localizedDescription)
            }
        }
    }
    func menuWillOpen(_ menu: NSMenu) { onMenuTracking?(true) }
    func menuDidClose(_ menu: NSMenu) {
        onMenuTracking?(false)
        // Choosing a native popup item may otherwise leave the popup as the key
        // responder, swallowing Return/arrow keys intended for the selection.
        if styleInspectorOpen, let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor { return }
        window?.makeFirstResponder(self)
    }
    func resetSelection() {
        styleInspectorOpen = false; stopStylePreview()
        gesture = nil; rectangle = .zero; ready = false; selectedWindow = nil; hoveredWindow = nil; refresh()
    }
    @objc func redrawSelection() { resetSelection(); window?.makeFirstResponder(self) }
    @objc func cancelSelection() { onFinish?(nil) }
    @objc func confirmSelection() {
        guard ready, gesture == nil else { return }
        guard !styleInspectorOpen || toolbar.inspector.commitColors(notify: true) else { NSSound.beep(); return }
        if let selectedWindow { onWindow?(selectedWindow) }
        else if rectangle.width >= 3 && rectangle.height >= 3 { onFinish?(rectangle) }
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        if ready {
            addCursorRect(rectangle, cursor: .openHand)
            for y in [rectangle.minY, rectangle.maxY] {
                addCursorRect(CGRect(x: rectangle.minX, y: y - 5, width: rectangle.width, height: 10).intersection(bounds), cursor: .resizeUpDown)
            }
            for x in [rectangle.minX, rectangle.maxX] {
                addCursorRect(CGRect(x: x - 5, y: rectangle.minY, width: 10, height: rectangle.height).intersection(bounds), cursor: .resizeLeftRight)
            }
            for handle in SelectionHandle.allCases {
                let point = handle.point(in: rectangle)
                let cursor: NSCursor = [.top, .bottom].contains(handle) ? .resizeUpDown : ([.left, .right].contains(handle) ? .resizeLeftRight : .crosshair)
                addCursorRect(CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14).intersection(bounds), cursor: cursor)
            }
        }
    }
    private func handle(at point: CGPoint) -> SelectionHandle? {
        if let handle = SelectionHandle.allCases.first(where: { handle in
            let anchor = handle.point(in: rectangle)
            return abs(point.x - anchor.x) <= 7 && abs(point.y - anchor.y) <= 7
        }) { return handle }
        if point.x >= rectangle.minX && point.x <= rectangle.maxX {
            if abs(point.y - rectangle.minY) <= 5 { return .top }
            if abs(point.y - rectangle.maxY) <= 5 { return .bottom }
        }
        if point.y >= rectangle.minY && point.y <= rectangle.maxY {
            if abs(point.x - rectangle.minX) <= 5 { return .left }
            if abs(point.x - rectangle.maxX) <= 5 { return .right }
        }
        return nil
    }
    override func mouseDown(with event: NSEvent) {
        if styleInspectorOpen {
            closeStyleInspector()
            guard !styleInspectorOpen else { return }
        }
        window?.makeKey(); window?.makeFirstResponder(self); onActivate?()
        let point = convert(event.locationInWindow, from: nil)
        if ready, let handle = handle(at: point) { gesture = .resize(rectangle, point, handle) }
        else if ready, rectangle.contains(point) { gesture = .move(rectangle, point) }
        else if windowMode { updateHoverAt(point); return }
        else { selectedWindow = nil; ready = false; rectangle = .zero; gesture = .create(point) }
        toolbar.isHidden = true; needsDisplay = true; publishGeometry(dragging: true)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let gesture else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch gesture {
        case .create(let start): rectangle = SelectionGeometry.rectangle(from: start, to: point, in: bounds, square: event.modifierFlags.contains(.shift))
        case .move(let original, let anchor):
            rectangle = SelectionGeometry.moved(original, by: CGSize(width: point.x - anchor.x, height: point.y - anchor.y), in: bounds)
            if rectangle != original { convertWindowToArea() }; NSCursor.closedHand.set()
        case .resize(let original, let anchor, let handle):
            rectangle = SelectionGeometry.resized(original, handle: handle, by: CGSize(width: point.x - anchor.x, height: point.y - anchor.y), in: bounds)
            if rectangle != original { convertWindowToArea() }
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        defer { publishGeometry() }
        if gesture != nil {
            mouseDragged(with: event); gesture = nil
            let valid = rectangle.width >= 3 && rectangle.height >= 3
            if adjustable { ready = valid; if !valid { rectangle = .zero }; refresh() }
            else if recordingSelection && externalRecordingControls && !valid { resetSelection() }
            else { onFinish?(valid ? rectangle : nil) }
        } else if windowMode, let hoveredWindow {
            if adjustable {
                selectedWindow = hoveredWindow; rectangle = hoveredWindow.frame.intersection(bounds)
                ready = !rectangle.isNull && !rectangle.isEmpty; refresh()
            } else { onWindow?(hoveredWindow) }
        }
    }
    private func convertWindowToArea() { if selectedWindow != nil { selectedWindow = nil; windowMode = false } }
    override func rightMouseDown(with event: NSEvent) { cancelSelection() }
    override func cancelOperation(_ sender: Any?) {
        if styleInspectorOpen { closeStyleInspector(discardInvalidInput: true) } else { cancelSelection() }
    }
    override func keyDown(with event: NSEvent) {
        if styleInspectorOpen {
            if event.keyCode == 53 { closeStyleInspector(discardInvalidInput: true) }
            else if event.keyCode == 36 || event.keyCode == 76 { closeStyleInspector() }
            else { super.keyDown(with: event) }
            return
        }
        if event.keyCode == 53 { cancelSelection() }
        else if event.keyCode == 36 || event.keyCode == 76 { confirmSelection() }
        else if event.keyCode == 49 && !windows.isEmpty {
            windowMode.toggle(); resetSelection(); onToggleWindowMode?(windowMode)
            updateHoverAt(convert(window?.convertPoint(fromScreen: NSEvent.mouseLocation) ?? .zero, from: nil))
        } else if ready, (123...126).contains(event.keyCode), event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            let step = event.modifierFlags.contains(.shift) ? 10.0 : 1.0
            let delta = CGSize(width: event.keyCode == 123 ? -step : (event.keyCode == 124 ? step : 0),
                               height: event.keyCode == 126 ? -step : (event.keyCode == 125 ? step : 0))
            convertWindowToArea(); rectangle = SelectionGeometry.moved(rectangle, by: delta, in: bounds); refresh()
        } else { super.keyDown(with: event) }
    }
    override func mouseMoved(with event: NSEvent) { if windowMode && !ready { updateHoverAt(convert(event.locationInWindow, from: nil)) } }
    private func updateHoverAt(_ point: CGPoint) { hoveredWindow = windows.first { $0.frame.contains(point) }; needsDisplay = true }
    private func refresh() {
        needsDisplay = true; window?.invalidateCursorRects(for: self)
        toolbar.isHidden = !ready || externalRecordingControls
        window?.defaultButtonCell = ready && !styleInspectorOpen && !externalRecordingControls ? toolbar.confirm.cell as? NSButtonCell : nil
        toolbar.inspector.isHidden = !styleInspectorOpen
        toolbar.customize.title = ""
        toolbar.customize.toolTip = styleInspectorOpen ? "完成样式调整" : "自定义本次样式"
        toolbar.customize.state = styleInspectorOpen ? .on : .off
        publishGeometry()
        guard ready else { return }
        let size = SelectionGeometry.pixelSize(for: selectedWindow?.frame ?? rectangle, backingScale: scale)
        toolbar.info.stringValue = "\(Int(size.width)) × \(Int(size.height)) px"
        if let appearance = outputAppearance {
            toolbar.styles.title = appearance.enabled ? "样式：\(appearance.name)" : "样式：普通截图"
            toolbar.styles.toolTip = "本次样式：\(appearance.enabled ? appearance.name : "普通截图")；仅影响这一次截图，不改变默认预设。"
            let selected = !appearance.enabled ? -1 : (presets.firstIndex { $0.name == appearance.name && $0.style == appearance.style } ?? presets.firstIndex { $0.style == appearance.style } ?? -2)
            for item in toolbar.styles.menu?.items ?? [] where item.action != nil { item.state = item.tag == selected ? .on : .off }
        }
        toolbar.frame = SelectionGeometry.toolbarFrame(for: rectangle, size: CGSize(width: 420, height: styleInspectorOpen ? SelectionToolbar.expandedHeight : SelectionToolbar.compactHeight), in: bounds)
        toolbar.needsLayout = true
        requestStylePreview()
    }
    override func draw(_ dirtyRect: NSRect) {
        if let frozenImage {
            NSGraphicsContext.current?.imageInterpolation = .none
            frozenImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        }
        let visible = rectangle.width > 0 ? rectangle : (windowMode ? hoveredWindow?.frame ?? .zero : .zero)
        let shade = NSBezierPath(rect: bounds)
        if !visible.isEmpty { shade.append(NSBezierPath(rect: visible)); shade.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(0.38).setFill(); shade.fill()
        if !visible.isEmpty {
            NSColor.black.withAlphaComponent(0.45).setStroke()
            let outer = NSBezierPath(rect: visible.insetBy(dx: -1, dy: -1)); outer.lineWidth = 2; outer.stroke()
            CaptureTheme.accentNS.setStroke()
            let path = NSBezierPath(rect: visible.insetBy(dx: 0.5, dy: 0.5)); path.lineWidth = 1.5; path.stroke()
            if ready {
                for handle in SelectionHandle.allCases {
                    let point = handle.point(in: visible), rect = CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
                    NSColor.white.setFill(); NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
                    CaptureTheme.accentNS.setStroke(); NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).stroke()
                }
            } else {
                let size = SelectionGeometry.pixelSize(for: visible, backingScale: scale)
                let label = windowMode ? String((hoveredWindow?.title ?? "窗口").prefix(32)) : "\(Int(size.width)) × \(Int(size.height)) px"
                drawPill(label, at: CGPoint(x: min(bounds.width - 250, max(10, visible.midX - 120)), y: min(bounds.height - 45, max(10, visible.maxY + 12))), width: 240)
            }
        }
        let hint: String
        if recordingSelection { hint = ready ? "框内拖动移动 · 边角缩放 · ↩ 开始" : (adjustable ? "框选后调整 · 回车开始 · Esc 取消" : "拖动框选 · 松手后录制 · Esc 取消") }
        else if ready && styleInspectorOpen { hint = "样式调整中  ·  ↩ 收起  ·  Esc 收起" }
        else if ready { hint = "拖动调整  ·  ↩ 复制  ·  Esc 取消" }
        else if windowMode { hint = adjustable ? "点选窗口后确认   空格切换框选   Esc 取消" : "点选窗口   空格切换框选   Esc 取消" }
        else { hint = adjustable ? "拖动框选后调整   Shift 正方形   Esc 取消" : "拖动框选   Shift 正方形   Esc 取消" }
        if rectangle.isEmpty || ready {
            let text = !recordingSelection && frozenImage != nil ? "画面已定格  ·  " + hint : hint
            let width = min(bounds.width - 24, 460)
            drawPill(text, at: CGPoint(x: (bounds.width - width) / 2, y: 28), width: width)
        }
    }
    private func drawPill(_ text: String, at point: CGPoint, width: Double) {
        let rect = CGRect(origin: point, size: CGSize(width: width, height: 32))
        CaptureTheme.chromeNS.withAlphaComponent(0.98).setFill(); NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16).fill()
        NSColor.separatorColor.setStroke(); NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16).stroke()
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        (text as NSString).draw(in: rect.insetBy(dx: 4, dy: 7), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ])
    }
}

final class SelectionToolbar: NSVisualEffectView {
    static let compactHeight: CGFloat = 80
    static var expandedHeight: CGFloat { compactHeight + SelectionStyleInspector.height + 12 }
    let info = CaptureAlignedLabel(caption: "")
    let hint = CaptureAlignedLabel(caption: "拖动调整 · 方向键微调")
    let recordingNote = CaptureAlignedLabel(caption: "录制实时画面")
    let styles = CapturePopup(frame: .zero, pullsDown: true)
    let customize = CapturePanelButton(caption: "自定义", target: nil, action: nil)
    let inspector = SelectionStyleInspector()
    let inspectorScroll = NSScrollView()
    let redraw = CapturePanelButton(caption: "重选", target: nil, action: nil)
    let cancel = CapturePanelButton(symbol: NSImage(systemSymbolName: "xmark", accessibilityDescription: "取消截图")!, target: nil, action: nil)
    let confirm = CapturePanelButton(caption: "截图并复制 ↩", target: nil, action: nil)
    private let backplate = NSView()
    override var isFlipped: Bool { true }
    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 420, height: Self.compactHeight))
        material = .popover; blendingMode = .withinWindow; state = .active
        wantsLayer = true; layer?.cornerRadius = 16; layer?.masksToBounds = true
        layer?.borderWidth = 1
        // A material alone becomes too translucent over text and in Reduce Transparency.
        backplate.wantsLayer = true
        addSubview(backplate)
        updateMaterialColors()
        recordingNote.isHidden = true; recordingNote.font = .systemFont(ofSize: 11); recordingNote.textColor = .secondaryLabelColor; addSubview(recordingNote)
        info.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold); info.textColor = .labelColor
        hint.font = .systemFont(ofSize: 10); hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        info.lineBreakMode = .byTruncatingTail
        info.setAccessibilityLabel("选区像素尺寸与操作提示")
        styles.setAccessibilityLabel("本次截图样式"); styles.toolTip = "仅影响这一次截图，包含内置和自定义预设"
        styles.cell?.lineBreakMode = .byTruncatingTail
        customize.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        customize.imagePosition = .imageOnly; customize.setAccessibilityLabel("自定义本次截图样式")
        customize.toolTip = "直接调整背景、颜色、留白、圆角、阴影与窗口边框，仅用于本次截图"
        redraw.image = nil; redraw.imagePosition = .noImage
        redraw.toolTip = "重新选择区域，保留本次样式"; redraw.setAccessibilityLabel("重新选择截图范围")
        cancel.title = ""; cancel.toolTip = "取消截图（Esc）"; cancel.setAccessibilityLabel("取消截图")
        confirm.toolTip = "确认范围与本次样式（Return）"
        for control in [styles, customize, redraw, cancel, confirm] {
            control.controlSize = .regular; control.font = .systemFont(ofSize: 12, weight: .medium)
            addSubview(control)
        }
        for button in [customize, redraw, cancel, confirm] { button.isBordered = false }
        confirm.primary = true
        inspectorScroll.drawsBackground = false; inspectorScroll.hasVerticalScroller = true; inspectorScroll.autohidesScrollers = true
        inspectorScroll.documentView = inspector; inspectorScroll.isHidden = true; inspector.isHidden = true; addSubview(inspectorScroll)
        addSubview(info); addSubview(hint)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateMaterialColors() }
    private func updateMaterialColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            backplate.layer?.backgroundColor = CaptureTheme.chromeNS.withAlphaComponent(0.98).cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func mouseDown(with event: NSEvent) {}
    override func layout() {
        super.layout()
        backplate.frame = bounds
        info.frame = CGRect(x: 14, y: 8, width: 125, height: 30)
        recordingNote.frame = CGRect(x: 145, y: 8, width: bounds.width - 159, height: 30)
        styles.frame = CGRect(x: 145, y: 8, width: bounds.width - 195, height: 30)
        customize.frame = CGRect(x: bounds.width - 44, y: 8, width: 30, height: 30)
        hint.frame = CGRect(x: 14, y: 42, width: max(0, bounds.width - 250), height: 30)
        redraw.frame = CGRect(x: bounds.width - 224, y: 42, width: 67, height: 30)
        cancel.frame = CGRect(x: bounds.width - 153, y: 42, width: 30, height: 30)
        confirm.frame = CGRect(x: bounds.width - 118, y: 42, width: 104, height: 30)
        inspectorScroll.isHidden = inspector.isHidden
        inspectorScroll.frame = CGRect(x: 16, y: Self.compactHeight, width: bounds.width - 32, height: max(0, bounds.height - Self.compactHeight - 12))
        inspector.frame = CGRect(x: 0, y: 0, width: inspectorScroll.contentSize.width, height: SelectionStyleInspector.height)
    }
    static func swatch(_ style: CaptureStyle) -> NSImage {
        let image = NSImage(size: CGSize(width: 42, height: 28))
        image.lockFocus(); defer { image.unlockFocus() }
        let path = NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 42, height: 28), xRadius: 5, yRadius: 5)
        func color(_ value: CaptureCore.RGBColor) -> NSColor { NSColor(srgbRed: value.red, green: value.green, blue: value.blue, alpha: 1) }
        NSGradient(starting: color(style.firstColor), ending: color(style.secondColor))?.draw(in: path, angle: -35)
        NSColor.white.setFill(); NSBezierPath(roundedRect: CGRect(x: 9, y: 6, width: 24, height: 16), xRadius: 2, yRadius: 2).fill()
        if style.windowFrame {
            (style.windowAppearance == .dark ? NSColor.darkGray : .lightGray).setFill()
            NSBezierPath(rect: CGRect(x: 9, y: 18, width: 24, height: 4)).fill()
        }
        return image
    }
}
