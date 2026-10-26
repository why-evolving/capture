import AppKit
import CaptureCore

/// Drives the real selection view with local events over a generated sample only.
@MainActor
enum SelectionChecks {
    static func run(store: AppStore, directory: URL) async throws -> [String] {
        let before = store.preferences
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 940, height: 660))
        let sample = SampleImage.make(width: 1440, height: 900)
        let image = NSImageView(frame: root.bounds)
        image.image = NSImage(cgImage: sample, size: CGSize(width: 1440, height: 900)); image.imageScaling = .scaleAxesIndependently
        root.addSubview(image)
        let view = SelectionView(frame: root.bounds); view.scale = 2; view.adjustable = true
        var customStyle = CaptureStyle(); customStyle.windowFrame = true; customStyle.windowAppearance = .dark
        let custom = StylePreset(name: "工作分享 · 测试", style: customStyle)
        let presets = StylePreset.builtIns + [custom]
        let initial = SelectionAppearance(style: store.captureStyle, enabled: store.preferences.automaticStyle, name: store.defaultName)
        view.configureStyles(presets: presets, appearance: initial, confirmTitle: "截图并复制")
        root.addSubview(view)
        let window = SelectionPanel(contentRect: root.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "Capture · 选区交互测试"; window.isReleasedWhenClosed = false; window.contentView = root
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(view)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 120_000_000)
        var finished: [CGRect?] = [], chosen: [CGWindowID] = []
        view.onFinish = { finished.append($0) }
        view.onWindow = { chosen.append($0.id) }

        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func drag(_ start: CGPoint, _ end: CGPoint) {
            view.mouseDown(with: event(.leftMouseDown, start)); view.mouseDragged(with: event(.leftMouseDragged, end)); view.mouseUp(with: event(.leftMouseUp, end))
        }
        func key(_ code: UInt16, shift: Bool = false) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
            window.makeFirstResponder(view); window.sendEvent(event)
        }
        drag(CGPoint(x: 110, y: 140), CGPoint(x: 620, y: 420))
        try require(view.ready && !view.toolbar.isHidden && finished.isEmpty, "调整模式松手后没有保留选区或提前触发截图")
        drag(CGPoint(x: 300, y: 260), CGPoint(x: 340, y: 280))
        try require(view.rectangle == CGRect(x: 150, y: 160, width: 510, height: 280) && finished.isEmpty, "移动选区改变了尺寸或提前截图")
        drag(CGPoint(x: 660, y: 440), CGPoint(x: 710, y: 480))
        try require(view.rectangle == CGRect(x: 150, y: 160, width: 560, height: 320), "选区控制点未正确调整范围")
        key(124); key(125, shift: true)
        try require(view.rectangle.origin == CGPoint(x: 151, y: 170), "方向键或 Shift 加速微调没有正确移动选区")
        let selected = view.rectangle
        guard let menu = view.toolbar.styles.menu,
              let customIndex = menu.items.firstIndex(where: { $0.tag == presets.count - 1 && $0.action != nil }),
              let plainIndex = menu.items.firstIndex(where: { $0.tag == -1 && $0.action != nil }) else { throw DeveloperChecks.CheckFailure("选区样式菜单缺少自定义或普通截图") }
        menu.performActionForItem(at: customIndex)
        try require(view.outputAppearance == SelectionAppearance(style: customStyle, enabled: true, name: custom.name), "选区菜单未应用自定义样式")
        menu.performActionForItem(at: plainIndex)
        try require(view.outputAppearance?.enabled == false && view.rectangle == selected && finished.isEmpty, "普通截图切换改变了范围或提前截图")
        menu.performActionForItem(at: customIndex)
        try require(store.preferences == before && view.toolbar.styles.title.contains(custom.name), "本次样式修改了截图默认或未显示选中样式")
        var opened = false, closed = false
        view.onMenuTracking = { tracking in if tracking { opened = true } else { closed = true } }
        let dismissMenu = Timer(timeInterval: 0.35, repeats: false) { _ in MainActor.assumeIsolated { menu.cancelTracking() } }
        RunLoop.main.add(dismissMenu, forMode: .common)
        view.toolbar.styles.performClick(nil)
        dismissMenu.invalidate()
        try require(opened && closed && view.ready && finished.isEmpty && window.firstResponder === view, "样式菜单不能正常关闭并将焦点交回待确认选区")
        root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        try snapshot(root, to: directory.appendingPathComponent("selection-adjustment.png"))
        key(36)
        try require(finished.count == 1 && finished[0] == selected && chosen.isEmpty, "回车没有仅确认一次调整后的范围")

        // The toolbar uses actual native button targets, not test-only closures.
        view.toolbar.redraw.performClick(nil)
        try require(!view.ready && view.rectangle.isEmpty && view.outputAppearance?.name == custom.name && finished.count == 1, "重新框选没有清空范围并保留本次样式")
        key(36)
        try require(finished.count == 1, "空选区按回车仍然确认")
        drag(CGPoint(x: 930, y: 650), CGPoint(x: 650, y: 490))
        try require(view.bounds.contains(view.toolbar.frame), "靠近屏幕边缘时浮动工具条超出显示范围")
        view.toolbar.confirm.performClick(nil)
        try require(finished.count == 2 && finished[1] == view.rectangle, "工具条确认按钮没有使用当前选区")
        key(53)
        try require(finished.count == 3 && finished[2] == nil, "Esc 没有取消选区")
        finished.removeAll(); view.resetSelection()
        drag(CGPoint(x: 300, y: 300), CGPoint(x: 300, y: 300))
        try require(!view.ready && finished.isEmpty, "无效小选区退出了调整模式或触发截图")
        view.adjustable = false
        drag(CGPoint(x: 120, y: 160), CGPoint(x: 430, y: 390))
        try require(finished.count == 1 && finished[0] == CGRect(x: 120, y: 160, width: 310, height: 230), "松手即截模式发生回归")

        finished.removeAll(); view.resetSelection(); view.adjustable = true; view.windowMode = true
        let sampleWindow = CaptureWindow(id: 1234, title: "测试窗口", frame: CGRect(x: 210, y: 180, width: 370, height: 260))
        view.windows = [sampleWindow]
        let point = CGPoint(x: 320, y: 280)
        view.mouseMoved(with: event(.mouseMoved, point)); view.mouseDown(with: event(.leftMouseDown, point)); view.mouseUp(with: event(.leftMouseUp, point))
        try require(view.ready && chosen.isEmpty && finished.isEmpty, "窗口调整模式点选后提前截图")
        view.toolbar.confirm.performClick(nil)
        try require(chosen == [sampleWindow.id] && finished.isEmpty, "未调整窗口的确认丢失窗口截图身份")
        drag(point, CGPoint(x: point.x + 30, y: point.y + 20))
        view.toolbar.confirm.performClick(nil)
        try require(chosen.count == 1 && finished.last! == CGRect(x: 240, y: 200, width: 370, height: 260), "调整窗口后没有改用准确的区域截图")
        key(49)
        try require(!view.ready && view.rectangle.isEmpty && view.outputAppearance?.name == custom.name, "空格切换模式没有重置选区并保留本次样式")
        view.toolbar.cancel.performClick(nil)
        try require(finished.last! == nil, "工具条取消按钮没有取消截图")
        // Route events through AppKit hit testing rather than calling view handlers directly.
        view.windowMode = false; view.adjustable = true; view.redrawSelection()
        let frozenSource = SampleImage.make(width: 1880, height: 1320)
        view.frozenFrame = try FrozenFrame(image: frozenSource, pointSize: root.bounds.size)
        func routedDrag(_ start: CGPoint, _ end: CGPoint) {
            window.sendEvent(event(.leftMouseDown, start))
            window.sendEvent(event(.leftMouseDragged, end))
            window.sendEvent(event(.leftMouseUp, end))
        }
        routedDrag(CGPoint(x: 100, y: 120), CGPoint(x: 600, y: 400))
        try require(view.ready && view.rectangle == CGRect(x: 100, y: 120, width: 500, height: 280), "真实命中路径没有创建选区")
        let panelFrame = window.frame
        routedDrag(CGPoint(x: 300, y: 260), CGPoint(x: 350, y: 290))
        try require(view.rectangle == CGRect(x: 150, y: 150, width: 500, height: 280) && window.frame == panelFrame, "拖动内部没有移动选区，或错误移动了整块遮罩窗口")
        routedDrag(CGPoint(x: 230, y: 150), CGPoint(x: 230, y: 130))
        try require(view.rectangle == CGRect(x: 150, y: 130, width: 500, height: 300), "没有手柄的边线无法缩放")
        try require(view.frozenFrame?.image === frozenSource, "移动选区替换了冻结帧")
        image.isHidden = true // The overlay must display its frame even after the underlying content disappears.
        try snapshot(root, to: directory.appendingPathComponent("selection-frozen-routed.png"))
        let beforeCustom = view.rectangle, beforeFinish = finished.count
        func click(_ control: NSControl) {
            root.layoutSubtreeIfNeeded()
            let point = control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: view)
            window.sendEvent(event(.leftMouseDown, point)); window.sendEvent(event(.leftMouseUp, point))
        }
        func action(_ control: NSControl) { _ = control.sendAction(control.action, to: control.target) }
        click(view.toolbar.customize)
        try require(view.styleInspectorOpen && view.bounds.contains(view.toolbar.frame) && view.rectangle == beforeCustom && finished.count == beforeFinish,
                    "自定义入口真实点击未展开或意外确认/改变选区")
        let inspector = view.toolbar.inspector
        func section(_ index: Int) {
            root.layoutSubtreeIfNeeded()
            let control = inspector.sections
            let point = control.convert(CGPoint(x: control.bounds.width * (index == 0 ? 0.25 : 0.75), y: control.bounds.midY), to: view)
            window.sendEvent(event(.leftMouseDown, point)); window.sendEvent(event(.leftMouseUp, point))
            root.layoutSubtreeIfNeeded()
        }
        section(1)
        try require(inspector.sections.selectedSegment == 1 && inspector.background.isHidden && !inspector.padding.isHidden && view.rectangle == beforeCustom && store.preferences == before && finished.count == beforeFinish,
                    "外观页签未正确切页：selected=\(inspector.sections.selectedSegment), backgroundHidden=\(inspector.background.isHidden), paddingHidden=\(inspector.padding.isHidden), regionSame=\(view.rectangle == beforeCustom), preferencesSame=\(store.preferences == before), finished=\(finished.count)")
        try snapshot(root, to: directory.appendingPathComponent("selection-custom-appearance.png"))
        section(0)
        try require(!inspector.background.isHidden && inspector.padding.isHidden, "背景页签没有隐藏外观参数")
        inspector.background.selectedSegment = BackgroundKind.allCases.firstIndex(of: .transparent)!; action(inspector.background)
        try require(!inspector.firstChip.isEnabled && !inspector.secondChip.isEnabled && !inspector.firstColor.isEnabled && !inspector.secondColor.isEnabled && !inspector.angle.isEnabled,
                    "透明背景仍可操作无效的颜色/方向控件")
        inspector.background.selectedSegment = BackgroundKind.allCases.firstIndex(of: .solid)!; action(inspector.background)
        try require(inspector.firstChip.isEnabled && !inspector.secondChip.isEnabled && !inspector.angle.isEnabled, "纯色背景没有只启用起始色")
        let dismissColors = Timer(timeInterval: 0.25, repeats: false) { _ in MainActor.assumeIsolated { inspector.colorMenu?.cancelTracking() } }
        RunLoop.main.add(dismissColors, forMode: .common)
        click(inspector.firstChip); dismissColors.invalidate()
        guard let colorMenu = inspector.colorMenu else { throw DeveloperChecks.CheckFailure("颜色块没有打开色板") }
        colorMenu.performActionForItem(at: 2)
        try require(view.outputAppearance?.style.firstColor.hex == "4A85E8" && view.styleInspectorOpen && finished.count == beforeFinish,
                    "色板点选没有应用本次颜色或意外确认")
        inspector.padding.doubleValue = 137; action(inspector.padding)
        inspector.radius.doubleValue = 23; action(inspector.radius)
        inspector.shadowStrength.doubleValue = 61; action(inspector.shadowStrength)
        inspector.angle.doubleValue = 215; action(inspector.angle)
        inspector.background.selectedSegment = BackgroundKind.allCases.firstIndex(of: .aurora)!; action(inspector.background)
        inspector.frameStyle.selectItem(at: 2); action(inspector.frameStyle)
        inspector.ratio.selectItem(at: CanvasRatio.allCases.firstIndex(of: .wide)!); action(inspector.ratio)
        inspector.firstColor.stringValue = "#2A75C4"; inspector.secondColor.stringValue = "#F2A75B"
        inspector.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: inspector.firstColor))
        guard let customized = view.outputAppearance else { throw DeveloperChecks.CheckFailure("自定义没有生成本次样式") }
        try require(customized.enabled && customized.name == "自定义" && customized.style.padding == 137 && customized.style.radius == 23 && customized.style.shadow == 61 && customized.style.angle == 215 && customized.style.background == .aurora && customized.style.windowFrame && customized.style.windowAppearance == .dark && customized.style.ratio == .wide && customized.style.firstColor.hex == "2A75C4" && customized.style.secondColor.hex == "F2A75B",
                    "自定义控件没有生成完整有效的本次样式")
        try require(store.preferences == before && view.rectangle == beforeCustom && finished.count == beforeFinish, "自定义污染默认预设或提前采集")
        // Wait on bounded conditions, not a single assumed renderer duration.
        for _ in 0..<50 where inspector.preview.image == nil { try await Task.sleep(nanoseconds: 30_000_000) }
        try require(inspector.preview.image != nil, "冻结选区自定义预览没有完成")
        window.makeFirstResponder(inspector.firstColor)
        let fieldReturn = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        window.sendEvent(fieldReturn)
        try require(finished.count == beforeFinish, "颜色输入中的Return意外截图")
        // Reopen if the field responder intentionally finished the inspector.
        if !view.styleInspectorOpen { click(view.toolbar.customize) }
        inspector.firstColor.stringValue = "#GG1234"
        inspector.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: inspector.firstColor))
        section(1)
        try require(inspector.sections.selectedSegment == 0 && !inspector.firstColor.isHidden && view.outputAppearance == customized, "无效颜色被切页隐藏或覆盖有效样式")
        view.toolbar.confirm.performClick(nil)
        try require(finished.count == beforeFinish && view.styleInspectorOpen && view.outputAppearance == customized, "无效颜色被静默用于截图或破坏了最后有效样式")
        window.makeFirstResponder(inspector.firstColor)
        let fieldEscape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        window.sendEvent(fieldEscape)
        try require(!view.styleInspectorOpen && view.ready && finished.count == beforeFinish && view.outputAppearance == customized, "Esc没有先收起样式面板或丢失有效调整")
        click(view.toolbar.customize); key(36)
        try require(!view.styleInspectorOpen && finished.count == beforeFinish, "面板内Return意外截图")
        click(view.toolbar.customize)
        inspector.padding.doubleValue = 20; action(inspector.padding)
        inspector.padding.doubleValue = 180; action(inspector.padding)
        try await Task.sleep(nanoseconds: 350_000_000)
        let expectedPreview = try StyleCompositor.render(try view.frozenFrame!.cropped(to: view.rectangle), style: view.outputAppearance!.style, previewLimit: 820)
        var previewRect = inspector.preview.bounds
        guard let actualPreview = inspector.preview.image?.cgImage(forProposedRect: &previewRect, context: nil, hints: nil) else { throw DeveloperChecks.CheckFailure("自定义预览丢失") }
        try require(try StyleCompositor.encode(actualPreview) == StyleCompositor.encode(expectedPreview), "连续调整时旧预览覆盖新样式")
        root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try require(view.toolbar.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua && inspector.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua,
                    "浅色应用中的选区面板仍强制深色")
        guard let plate = view.toolbar.bitmapImageRepForCachingDisplay(in: view.toolbar.bounds),
              let previewColor = inspector.preview.layer?.backgroundColor.flatMap({ NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }) else { throw DeveloperChecks.CheckFailure("无法检查选区浅色渲染") }
        view.toolbar.cacheDisplay(in: view.toolbar.bounds, to: plate)
        guard let plateColor = plate.colorAt(x: 8, y: 200)?.usingColorSpace(.sRGB) else { throw DeveloperChecks.CheckFailure("选区面板像素为空") }
        try require(min(plateColor.redComponent, plateColor.greenComponent, plateColor.blueComponent) > 0.8 && min(previewColor.redComponent, previewColor.greenComponent, previewColor.blueComponent) > 0.85,
                    "选区卡片或预览留白仍使用暗色底板")
        try snapshot(root, to: directory.appendingPathComponent("selection-custom-style.png"))
        let pixelScale = CGFloat(plate.pixelsWide) / view.toolbar.bounds.width
        for button in [view.toolbar.redraw, view.toolbar.cancel] {
            let point = button.convert(CGPoint(x: 5, y: button.bounds.midY), to: view.toolbar)
            guard let color = plate.colorAt(x: Int(point.x * pixelScale), y: Int(point.y * pixelScale))?.usingColorSpace(.sRGB) else { throw DeveloperChecks.CheckFailure("选区次按钮像素为空") }
            try require(min(color.redComponent, color.greenComponent, color.blueComponent) > 0.8, "选区次按钮像素错误: \(color), button=\(button.title), point=\(point), scale=\(pixelScale)")
        }
        inspector.reset.performClick(nil)
        try require(view.outputAppearance == initial && store.preferences == before, "本次还原没有恢复开始时样式或更改了默认")
        menu.performActionForItem(at: plainIndex)
        inspector.padding.doubleValue = 88; action(inspector.padding)
        try require(view.outputAppearance?.enabled == true && view.outputAppearance?.style.padding == 88, "普通截图中自定义没有自动启用美化")
        view.toolbar.redraw.performClick(nil)
        try require(!view.styleInspectorOpen && inspector.isHidden && !view.ready && view.outputAppearance?.style.padding == 88, "重选没有收起面板并保留本次自定义")
        routedDrag(CGPoint(x: 900, y: 630), CGPoint(x: 650, y: 500))
        click(view.toolbar.customize)
        try require(view.bounds.contains(view.toolbar.frame) && view.toolbar.bounds.contains(inspector.frame), "屏幕边缘展开自定义控件被裁切")
        key(53); key(36)
        try require(finished.count == beforeFinish + 1 && view.outputAppearance?.style.padding == 88, "自定义后确认丢失本次参数")
        view.resetSelection(); view.setFrameSize(CGSize(width: 600, height: 400))
        drag(CGPoint(x: 50, y: 70), CGPoint(x: 500, y: 300)); click(view.toolbar.customize)
        root.layoutSubtreeIfNeeded()
        try require(view.bounds.contains(view.toolbar.frame) && view.toolbar.bounds.contains(view.toolbar.inspectorScroll.frame) && view.toolbar.inspectorScroll.contentSize.height < inspector.bounds.height,
                    "低分辨率画面没有保持主操作可见并允许滚动参数")
        view.stopStylePreview()
        return ["selection-release-waits-for-confirmation", "selection-move-keeps-size", "selection-resize-handles", "selection-keyboard-nudge", "selection-style-menu-and-plain-mode", "selection-style-does-not-replace-default", "selection-native-style-menu-opens-and-closes", "selection-return-confirms-once", "selection-redraw-retains-style", "selection-toolbar-fits-display-edge", "selection-toolbar-confirm-and-cancel", "selection-invalid-area-stays-open", "quick-selection-still-captures-on-release", "window-selection-waits-and-keeps-identity", "adjusted-window-becomes-region", "selection-space-reset-retains-style", "selection-appkit-hit-test-create", "selection-appkit-move-not-panel", "selection-full-edge-resize", "selection-keeps-frozen-frame", "selection-custom-native-button-opens", "selection-custom-all-controls-and-colors", "selection-custom-keeps-default-and-region", "selection-custom-invalid-color-blocks-confirmation", "selection-custom-escape-and-return-do-not-capture", "selection-custom-preview-latest-wins", "selection-custom-reset-and-enable-from-plain", "selection-custom-redraw-retains-and-edge-fits", "selection-custom-color-palette", "selection-custom-text-field-keyboard", "selection-light-interface-and-preview", "selection-custom-section-native-routing", "selection-custom-invalid-color-keeps-section", "selection-secondary-button-pixels"]
    }
    private static func require(_ value: Bool, _ message: String) throws { if !value { throw DeveloperChecks.CheckFailure(message) } }
    private static func snapshot(_ view: NSView, to url: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw DeveloperChecks.CheckFailure("选区界面预览分配失败") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let pixels = bitmap.cgImage else { throw DeveloperChecks.CheckFailure("选区界面预览为空") }
        try StyleCompositor.encode(pixels).write(to: url, options: .atomic)
    }
}
