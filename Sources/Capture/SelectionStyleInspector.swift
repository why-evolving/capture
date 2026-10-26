import AppKit
import CaptureCore

/// A session-only inspector embedded in the selection bubble. It never owns preferences.
final class SelectionStyleInspector: NSView, NSTextFieldDelegate {
    static let height: CGFloat = 364
    var onChange: ((SelectionAppearance) -> Void)?
    var onReset: (() -> Void)?
    var onClose: (() -> Void)?
    let enabled = NSButton(checkboxWithTitle: "应用美化", target: nil, action: nil)
    let reset = CapturePanelButton(caption: "还原", target: nil, action: nil)
    let preview = NSImageView()
    let previewStatus = CaptureAlignedLabel(caption: "正在生成预览…")
    let background = CaptureNativeSegments(items: BackgroundKind.allCases.map(\.label), target: nil, action: nil)
    let firstColor = CapturePanelField(frame: .zero), secondColor = CapturePanelField(frame: .zero)
    let padding = CaptureNativeSlider(settingValue: 96, minValue: 0, maxValue: 240, target: nil, action: nil)
    let radius = CaptureNativeSlider(settingValue: 16, minValue: 0, maxValue: 48, target: nil, action: nil)
    let shadowStrength = CaptureNativeSlider(settingValue: 40, minValue: 0, maxValue: 100, target: nil, action: nil)
    let angle = CaptureNativeSlider(settingValue: 135, minValue: 0, maxValue: 360, target: nil, action: nil)
    let frameStyle = CapturePopup(frame: .zero, pullsDown: false), ratio = CapturePopup(frame: .zero, pullsDown: false)
    let sections = CaptureNativeSegments(items: ["背景", "外观"], target: nil, action: nil)
    let border = NSButton(checkboxWithTitle: "细描边", target: nil, action: nil)
    let grain = NSButton(checkboxWithTitle: "背景颗粒", target: nil, action: nil)
    private let colorError = CaptureAlignedLabel(caption: "")
    private let note = CaptureAlignedLabel(caption: "仅本次截图生效 · 不更改默认预设")
    let firstChip = NSButton(), secondChip = NSButton()
    private(set) var colorMenu: NSMenu?
    private let sliderLabels = ["留白", "圆角", "阴影", "方向"].map { CaptureAlignedLabel(caption: $0) }
    private let sliderValues = (0..<4).map { _ in CaptureAlignedLabel(caption: "") }
    private var model = SelectionAppearance(style: CaptureStyle(), enabled: false, name: "自定义")
    private var visibleSection = 0
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init() {
        super.init(frame: .zero)
        sections.selectedSegment = 0; sections.target = self; sections.action = #selector(changeSection)
        sections.setAccessibilityLabel("自定义样式分类")
        enabled.target = self; enabled.action = #selector(toggleEnabled)
        reset.target = self; reset.action = #selector(resetStyle)
        background.target = self; background.action = #selector(changeStyle)
        frameStyle.addItems(withTitles: ["无窗口边框", "macOS 浅色", "macOS 深色"])
        ratio.addItems(withTitles: CanvasRatio.allCases.map { "画布 · " + $0.label })
        frameStyle.setAccessibilityLabel("本次窗口边框"); ratio.setAccessibilityLabel("本次画布比例")
        background.setAccessibilityLabel("本次背景类型")
        for control in [frameStyle, ratio, border, grain] as [NSControl] {
            control.target = self; control.action = #selector(changeStyle)
        }
        for (index, slider) in [padding, radius, shadowStrength, angle].enumerated() {
            slider.target = self; slider.action = #selector(changeStyle); slider.isContinuous = true
            slider.setAccessibilityLabel("本次" + sliderLabels[index].stringValue)
        }
        for (index, field) in [firstColor, secondColor].enumerated() {
            field.placeholderString = "#RRGGBB"; field.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            field.delegate = self; field.target = self; field.action = #selector(commitColor)
            field.setAccessibilityLabel(index == 0 ? "背景起始颜色 HEX" : "背景结束颜色 HEX")
            field.toolTip = "输入六位十六进制颜色，例如 #4A66F0；无效输入不会用于截图"
        }
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true; preview.layer?.cornerRadius = 10; preview.layer?.masksToBounds = true
        preview.layer?.borderWidth = 1
        updatePreviewColors()
        preview.setAccessibilityLabel("本次截图样式预览，导出使用原始像素")
        for (index, chip) in [firstChip, secondChip].enumerated() {
            chip.wantsLayer = true; chip.layer?.cornerRadius = 5; chip.isBordered = false; chip.title = ""
            chip.tag = index; chip.target = self; chip.action = #selector(openColorMenu(_:))
            chip.setAccessibilityLabel(index == 0 ? "选择背景起始颜色" : "选择背景结束颜色")
            chip.toolTip = "点选常用颜色，或在右侧输入任意 HEX 颜色"
        }
        for label in sliderLabels + sliderValues + [previewStatus, note, colorError] {
            label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
        }
        colorError.textColor = .systemOrange; colorError.font = .systemFont(ofSize: 10)
        note.font = .systemFont(ofSize: 10); previewStatus.alignment = .center
        for value in sliderValues { value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium); value.alignment = .right }
        let views: [NSView] = [enabled, reset, preview, previewStatus, sections, background, firstChip, firstColor, secondChip, secondColor,
            padding, radius, shadowStrength, angle, frameStyle, ratio, border, grain, colorError, note] + sliderLabels + sliderValues
        for view in views {
            if let control = view as? NSControl, !(control is NSTextField) { control.font = .systemFont(ofSize: 11, weight: .medium); control.controlSize = .small }
            addSubview(view)
        }
        apply(model)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updatePreviewColors() }
    private func updatePreviewColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            preview.layer?.backgroundColor = CaptureTheme.canvasNS.cgColor
            preview.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
    override func mouseDown(with event: NSEvent) {} // Whitespace must not start a new selection.
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func cancelOperation(_ sender: Any?) { apply(model); onClose?() }
    @objc private func resetStyle() { onReset?() }
    @objc private func toggleEnabled() {
        model.enabled = enabled.state == .on; onChange?(model)
    }
    func apply(_ appearance: SelectionAppearance) {
        model = appearance
        let style = appearance.style
        enabled.state = appearance.enabled ? .on : .off
        background.selectedSegment = BackgroundKind.allCases.firstIndex(of: style.background) ?? 0
        firstColor.stringValue = "#" + style.firstColor.hex; secondColor.stringValue = "#" + style.secondColor.hex
        padding.doubleValue = style.padding; radius.doubleValue = style.radius; shadowStrength.doubleValue = style.shadow; angle.doubleValue = style.angle
        frameStyle.selectItem(at: !style.windowFrame ? 0 : (style.windowAppearance == .light ? 1 : 2))
        ratio.selectItem(at: CanvasRatio.allCases.firstIndex(of: style.ratio) ?? 0)
        border.state = style.border ? .on : .off; grain.state = style.grain ? .on : .off
        updateLabels(); colorError.stringValue = ""
    }
    private func updateLabels() {
        for (index, slider) in [padding, radius, shadowStrength, angle].enumerated() {
            sliderValues[index].stringValue = "\(Int(slider.doubleValue.rounded()))" + (index == 3 ? "°" : (index < 2 ? " px" : "%"))
        }
        let style = model.style, hasColor = style.background != .transparent
        firstColor.isEnabled = hasColor
        secondColor.isEnabled = style.background == .gradient || style.background == .aurora
        firstChip.isEnabled = firstColor.isEnabled; secondChip.isEnabled = secondColor.isEnabled
        firstChip.alphaValue = firstChip.isEnabled ? 1 : 0.35; secondChip.alphaValue = secondChip.isEnabled ? 1 : 0.35
        angle.isEnabled = secondColor.isEnabled; grain.isEnabled = hasColor
        firstChip.layer?.backgroundColor = style.firstColor.cgColor; secondChip.layer?.backgroundColor = style.secondColor.cgColor
    }
    @objc private func changeStyle() {
        guard commitColors() else { return }
        var style = model.style
        style.background = BackgroundKind.allCases[max(0, background.selectedSegment)]
        style.padding = padding.doubleValue.rounded(); style.radius = radius.doubleValue.rounded()
        style.shadow = shadowStrength.doubleValue.rounded(); style.angle = angle.doubleValue.rounded()
        style.windowFrame = frameStyle.indexOfSelectedItem > 0
        style.windowAppearance = frameStyle.indexOfSelectedItem == 2 ? .dark : .light
        style.ratio = CanvasRatio.allCases[max(0, ratio.indexOfSelectedItem)]
        style.border = border.state == .on; style.grain = grain.state == .on
        guard style.isValid else { return }
        model = SelectionAppearance(style: style, enabled: true, name: "自定义")
        enabled.state = .on; updateLabels(); onChange?(model)
    }
    @objc private func commitColor() { _ = commitColors(notify: true) }
    @objc private func openColorMenu(_ sender: NSButton) {
        let menu = NSMenu(title: "选择颜色"); menu.delegate = frameStyle.menu?.delegate; colorMenu = menu
        let colors = [("暮光紫", "A494ED"), ("樱花粉", "F2B9B5"), ("海蓝", "4A85E8"), ("薄荷", "78D7BF"),
                      ("杏桃", "F2B474"), ("石墨", "393943"), ("雾白", "F1F3F7"), ("纯白", "FFFFFF")]
        for (name, hex) in colors {
            let item = NSMenuItem(title: name + "  #" + hex, action: #selector(selectColor(_:)), keyEquivalent: "")
            item.target = self; item.tag = sender.tag; item.representedObject = hex
            let image = NSImage(size: CGSize(width: 16, height: 16)); image.lockFocus()
            let color = CaptureCore.RGBColor(hex: hex)
            NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: 1, y: 1, width: 14, height: 14), xRadius: 4, yRadius: 4).fill()
            image.unlockFocus(); item.image = image; menu.addItem(item)
        }
        menu.addItem(.separator())
        let custom = NSMenuItem(title: "输入其他 HEX 颜色…", action: #selector(focusColor(_:)), keyEquivalent: "")
        custom.target = self; custom.tag = sender.tag; menu.addItem(custom)
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }
    @objc private func selectColor(_ sender: NSMenuItem) {
        guard let hex = sender.representedObject as? String else { return }
        (sender.tag == 0 ? firstColor : secondColor).stringValue = "#" + hex
        _ = commitColors(notify: true)
    }
    @objc private func focusColor(_ sender: NSMenuItem) {
        let field = sender.tag == 0 ? firstColor : secondColor
        field.selectText(nil)
    }
    func controlTextDidChange(_ obj: Notification) { _ = commitColors(notify: true) }
    @discardableResult func commitColors(notify: Bool = false) -> Bool {
        func parsed(_ field: NSTextField) -> CaptureCore.RGBColor? {
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let hex = text.hasPrefix("#") ? String(text.dropFirst()) : text
            guard hex.count == 6, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
            return CaptureCore.RGBColor(hex: hex)
        }
        guard let first = parsed(firstColor), let second = parsed(secondColor) else {
            colorError.stringValue = "颜色需为 6 位 HEX（如 #4A66F0），请修正后确认"
            return false
        }
        colorError.stringValue = ""
        guard model.style.firstColor != first || model.style.secondColor != second else { return true }
        model.style.firstColor = first; model.style.secondColor = second; model.enabled = true; model.name = "自定义"
        enabled.state = .on; updateLabels()
        if notify { onChange?(model) }
        return true
    }
    func showPreview(_ image: CGImage) {
        preview.image = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)); previewStatus.stringValue = ""
    }
    func showPreviewStatus(_ text: String) { previewStatus.stringValue = text }
    @objc private func changeSection() {
        guard commitColors() else { sections.selectedSegment = visibleSection; NSSound.beep(); return }
        visibleSection = sections.selectedSegment
        window?.makeFirstResponder(self); needsLayout = true
    }
    override func layout() {
        super.layout()
        let width = bounds.width, half = (width - 18) / 2, appearancePage = sections.selectedSegment == 1
        enabled.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        reset.frame = CGRect(x: width - 48, y: 0, width: 48, height: 26)
        reset.toolTip = "还原到本次截图开始时的样式"
        preview.frame = CGRect(x: 0, y: 30, width: width, height: 90)
        previewStatus.frame = CGRect(x: 8, y: 65, width: width - 16, height: 20)
        sections.frame = CGRect(x: 0, y: 132, width: width, height: 30)
        for item in [background, firstChip, secondChip, firstColor, secondColor, angle, grain, colorError, sliderLabels[3], sliderValues[3]] { item.isHidden = appearancePage }
        for item in [padding, radius, shadowStrength, frameStyle, ratio, border, sliderLabels[0], sliderLabels[1], sliderLabels[2], sliderValues[0], sliderValues[1], sliderValues[2]] { item.isHidden = !appearancePage }
        background.frame = CGRect(x: 0, y: 175, width: width, height: 28)
        firstChip.frame = CGRect(x: 0, y: 215, width: 25, height: 26)
        firstColor.frame = CGRect(x: 33, y: 215, width: half - 33, height: 26)
        secondChip.frame = CGRect(x: half + 18, y: 215, width: 25, height: 26)
        secondColor.frame = CGRect(x: half + 51, y: 215, width: half - 33, height: 26)
        colorError.frame = CGRect(x: 0, y: 244, width: width, height: 14)
        for (index, slider) in [padding, radius, shadowStrength, angle].enumerated() {
            let x: CGFloat = index < 2 && index % 2 == 1 ? half + 18 : 0
            let y: CGFloat = index < 2 ? 178 : (index == 2 ? 231 : 269)
            let available = index < 2 ? half : width
            sliderLabels[index].frame = CGRect(x: x, y: y, width: available - 65, height: 16)
            sliderValues[index].frame = CGRect(x: x + available - 65, y: y, width: 65, height: 16)
            slider.frame = CGRect(x: x, y: y + 20, width: available, height: 22)
        }
        frameStyle.frame = CGRect(x: 0, y: 285, width: half, height: 29)
        ratio.frame = CGRect(x: half + 18, y: 285, width: half, height: 29)
        border.frame = CGRect(x: 0, y: 320, width: half, height: 20)
        grain.frame = CGRect(x: 0, y: 318, width: width, height: 20)
        note.frame = CGRect(x: 0, y: 348, width: width, height: 16)
    }
}
