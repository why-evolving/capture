import AppKit
import SwiftUI

private typealias FieldFocus<Value: Hashable> = SwiftUI.FocusState<Value>

/// Native popup tracking and accessibility, shared with the selection inspector.
struct CaptureChoice<Value: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    init(_ title: String, selection: Binding<Value>, options: [(Value, String)]) {
        self.title = title; _selection = selection; self.options = options
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> CapturePopup {
        let popup = CapturePopup(frame: .zero, pullsDown: false)
        popup.target = context.coordinator; popup.action = #selector(Coordinator.changed(_:))
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return popup
    }
    func updateNSView(_ popup: CapturePopup, context: Context) {
        context.coordinator.owner = self
        popup.appearance = NSAppearance(named: context.environment.colorScheme == .dark ? .darkAqua : .aqua)
        let titles = options.map { $0.1 }
        if popup.itemTitles != titles { popup.removeAllItems(); popup.addItems(withTitles: titles) }
        popup.selectItem(at: options.firstIndex { $0.0 == selection } ?? -1)
        popup.isEnabled = context.environment.isEnabled
        popup.setAccessibilityLabel(title); popup.toolTip = title
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CapturePopup, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? max(90, nsView.intrinsicContentSize.width), height: 30)
    }
    final class Coordinator: NSObject {
        var owner: CaptureChoice
        init(_ owner: CaptureChoice) { self.owner = owner }
        @objc func changed(_ popup: NSPopUpButton) {
            guard popup.isEnabled, owner.options.indices.contains(popup.indexOfSelectedItem) else { return }
            owner.selection = owner.options[popup.indexOfSelectedItem].0
        }
    }
}

/// Compact native color well; the system owns color selection and keyboard behavior.
struct CaptureColorWell: NSViewRepresentable {
    let title: String
    @Binding var color: Color
    init(_ title: String, selection: Binding<Color>) { self.title = title; _color = selection }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSColorWell {
        let well = CaptureSwatchWell(frame: .zero); well.colorWellStyle = .minimal
        well.isBordered = false
        well.target = context.coordinator; well.action = #selector(Coordinator.changed(_:))
        well.setAccessibilityLabel(title); well.toolTip = title
        return well
    }
    func updateNSView(_ well: NSColorWell, context: Context) {
        context.coordinator.owner = self; well.appearance = NSAppearance(named: context.environment.colorScheme == .dark ? .darkAqua : .aqua); well.color = NSColor(color); well.isEnabled = context.environment.isEnabled
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSColorWell, context: Context) -> CGSize? { CGSize(width: 24, height: 24) }
    final class Coordinator: NSObject {
        var owner: CaptureColorWell
        init(_ owner: CaptureColorWell) { self.owner = owner }
        @objc func changed(_ well: NSColorWell) { if well.isEnabled { owner.color = Color(nsColor: well.color) } }
    }
}

private final class CaptureSwatchWell: NSColorWell {
    override var wantsUpdateLayer: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        color.withAlphaComponent(isEnabled ? 1 : 0.35).setFill(); path.fill()
        NSColor.labelColor.withAlphaComponent(0.12).setStroke(); path.lineWidth = 1; path.stroke()
    }
}

struct CaptureSegments<Value: Hashable>: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    init(_ title: String, selection: Binding<Value>, options: [(Value, String)]) {
        self.title = title; _selection = selection; self.options = options
    }
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button { selection = option.0 } label: {
                    Text(option.1).font(.system(size: 11, weight: selection == option.0 ? .semibold : .regular))
                        .foregroundStyle(selection == option.0 ? CaptureTheme.accent : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 27).contentShape(Rectangle())
                        .background(selection == option.0 ? CaptureTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(selection == option.0 ? 0.05 : 0), radius: 2, y: 1)
                }.buttonStyle(.plain).accessibilityLabel(title + " · " + option.1)
                    .accessibilityValue(selection == option.0 ? "已选中" : "未选中")
            }
        }.padding(3).background(CaptureTheme.canvas, in: RoundedRectangle(cornerRadius: 9))
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
    }
    private func move(_ delta: Int) {
        guard isEnabled, let index = options.firstIndex(where: { $0.0 == selection }), options.indices.contains(index + delta) else { return }
        selection = options[index + delta].0
    }
}

struct CaptureFieldStyle: TextFieldStyle {
    @FieldFocus private var focused: Bool
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).font(.system(size: 12)).focused($focused)
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(CaptureTheme.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(focused ? CaptureTheme.accent.opacity(0.7) : CaptureTheme.border, lineWidth: 1))
    }
}

struct CaptureSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onEditingChanged: (Bool) -> Void
    init(value: Binding<Double>, in range: ClosedRange<Double>, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _value = value; self.range = range; self.onEditingChanged = onEditingChanged
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> CaptureNativeSlider {
        let slider = CaptureNativeSlider(settingValue: value, minValue: range.lowerBound, maxValue: range.upperBound, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.isContinuous = true; return slider
    }
    func updateNSView(_ slider: CaptureNativeSlider, context: Context) {
        context.coordinator.owner = self; slider.appearance = NSAppearance(named: context.environment.colorScheme == .dark ? .darkAqua : .aqua); slider.minValue = range.lowerBound; slider.maxValue = range.upperBound
        slider.doubleValue = value; slider.isEnabled = context.environment.isEnabled; slider.onEditingChanged = onEditingChanged
    }
    final class Coordinator: NSObject {
        var owner: CaptureSlider
        init(_ owner: CaptureSlider) { self.owner = owner }
        @objc func changed(_ slider: NSSlider) { owner.value = slider.doubleValue }
    }
}

final class CaptureNativeSlider: NSSlider {
    override var allowsVibrancy: Bool { false }
    var onEditingChanged: ((Bool) -> Void)?
    convenience init(settingValue: Double, minValue: Double, maxValue: Double, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero); self.minValue = minValue; self.maxValue = maxValue; doubleValue = settingValue
        self.target = target; self.action = action
    }
    override init(frame: NSRect) { super.init(frame: frame); installCell() }
    required init?(coder: NSCoder) { super.init(coder: coder); installCell() }
    private func installCell() { cell = StudioSliderCell(); controlSize = .small; }
    override func mouseDown(with event: NSEvent) { onEditingChanged?(true); super.mouseDown(with: event); onEditingChanged?(false) }
}
private final class StudioSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let bar = CGRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        NSColor.labelColor.withAlphaComponent(0.09).setFill(); NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
        let fraction = maxValue > minValue ? min(1, max(0, (doubleValue - minValue) / (maxValue - minValue))) : 0
        CaptureTheme.accentNS.withAlphaComponent(isEnabled ? 1 : 0.35).setFill()
        NSBezierPath(roundedRect: CGRect(x: bar.minX, y: bar.minY, width: bar.width * fraction, height: bar.height), xRadius: 2, yRadius: 2).fill()
    }
    override func drawKnob(_ knobRect: NSRect) {
        let rect = CGRect(x: knobRect.midX - 6.5, y: knobRect.midY - 6.5, width: 13, height: 13)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.15); shadow.shadowBlurRadius = 3; shadow.shadowOffset = CGSize(width: 0, height: -1); shadow.set()
        NSColor.white.setFill(); NSBezierPath(ovalIn: rect).fill(); NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.12).setStroke(); NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
}

/// Keep AppKit's title/image, focus and target/action rendering; style its backing surface.
final class CapturePanelButton: NSButton {
    override var allowsVibrancy: Bool { false }
    var primary = false { didSet { updateSurface() } }
    override var state: NSControl.StateValue { didSet { updateSurface() } }
    override var isEnabled: Bool { didSet { updateSurface() } }
    convenience init(caption: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero); title = caption; self.target = target; self.action = action
    }
    convenience init(symbol: NSImage, target: AnyObject?, action: Selector?) {
        self.init(caption: "", target: target, action: action); image = symbol; imagePosition = .imageOnly
    }
    override init(frame: NSRect) {
        super.init(frame: frame); bezelStyle = .inline; isBordered = false; title = ""
        setButtonType(.momentaryPushIn); alignment = .center; wantsLayer = true
        font = .systemFont(ofSize: 11.5, weight: .medium); updateSurface()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); updateSurface() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateSurface() }
    private func updateSurface() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = 8; layer?.borderWidth = primary ? 0 : 0.7
            let surface = primary ? CaptureTheme.accentNS : (state == .on ? CaptureTheme.accentNS.withAlphaComponent(0.08) : NSColor.controlBackgroundColor)
            layer?.backgroundColor = surface.cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
            layer?.opacity = isEnabled ? 1 : 0.4
            contentTintColor = primary ? .white : (state == .on ? CaptureTheme.accentNS : .labelColor)
        }
    }
}

final class CapturePopup: NSPopUpButton {
    override var wantsUpdateLayer: Bool { false }
    override func draw(_ dirtyRect: NSRect) { effectiveAppearance.performAsCurrentDrawingAppearance { cell?.draw(withFrame: bounds, in: self) } }
    override var allowsVibrancy: Bool { false }
    override init(frame: NSRect, pullsDown flag: Bool) { super.init(frame: frame, pullsDown: flag); cell = StudioPopupCell(textCell: "", pullsDown: flag); isBordered = false }
    required init?(coder: NSCoder) { super.init(coder: coder) }
}
private final class StudioPopupCell: NSPopUpButtonCell {
    override func draw(withFrame frame: NSRect, in controlView: NSView) {
        let rect = frame.insetBy(dx: 0.5, dy: 1)
        NSColor.controlBackgroundColor.setFill(); let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7); path.fill()
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke(); path.lineWidth = 0.7; path.stroke()
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let textHeight = (title as NSString).size(withAttributes: [.font: font]).height
        (title as NSString).draw(in: CGRect(x: rect.minX + 10, y: rect.midY - textHeight / 2, width: max(0, rect.width - 32), height: textHeight), withAttributes: [.font: font, .foregroundColor: NSColor.labelColor.withAlphaComponent(isEnabled ? 1 : 0.4), .paragraphStyle: paragraph])
        NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.draw(in: CGRect(x: rect.maxX - 18, y: rect.midY - 4, width: 8, height: 8))
    }
}

final class CaptureNativeSegments: NSSegmentedControl {
    override var allowsVibrancy: Bool { false }
    override var wantsUpdateLayer: Bool { false }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if segmentCount > 0 { for index in 0..<segmentCount { setWidth(newSize.width / CGFloat(segmentCount), forSegment: index) } }
    }
    convenience init(items: [String], target: AnyObject?, action: Selector?) {
        self.init(frame: .zero); segmentCount = items.count; trackingMode = .selectOne
        for (index, label) in items.enumerated() { setLabel(label, forSegment: index) }
        self.target = target; self.action = action
    }
    override init(frame: NSRect) { super.init(frame: frame); cell = StudioSegmentCell(); segmentDistribution = .fillEqually }
    required init?(coder: NSCoder) { super.init(coder: coder) }
}
private final class StudioSegmentCell: NSSegmentedCell {
    override func draw(withFrame frame: NSRect, in controlView: NSView) {
        // Native drawing computes segment hit regions before our surface is painted.
        NSGraphicsContext.saveGraphicsState(); super.draw(withFrame: frame, in: controlView); NSGraphicsContext.restoreGraphicsState()
        CaptureTheme.chromeNS.setFill(); NSBezierPath(rect: frame).fill()
        CaptureTheme.canvasNS.setFill(); NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 1), xRadius: 8, yRadius: 8).fill()
        guard segmentCount > 0 else { return }
        let width = frame.width / CGFloat(segmentCount)
        for index in 0..<segmentCount {
            let rect = CGRect(x: frame.minX + CGFloat(index) * width + 3, y: frame.minY + 3, width: width - 6, height: frame.height - 6)
            if isSelected(forSegment: index) {
                NSColor.controlBackgroundColor.setFill(); NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            }
            let text = label(forSegment: index) ?? ""
            let font = NSFont.systemFont(ofSize: 11, weight: isSelected(forSegment: index) ? .semibold : .regular)
            let size = (text as NSString).size(withAttributes: [.font: font])
            (text as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: [.font: font, .foregroundColor: isSelected(forSegment: index) ? CaptureTheme.accentNS : NSColor.secondaryLabelColor])
        }
    }
}
/// A single text rectangle for display and field editing; no manual baseline offsets.
private final class CaptureCenteredTextCell: NSTextFieldCell {
    var horizontalInset: CGFloat = 0
    private func contentRect(_ bounds: NSRect) -> NSRect {
        let font = font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let height = min(bounds.height, ceil(font.ascender - font.descender + font.leading))
        return CGRect(x: bounds.minX + horizontalInset, y: bounds.midY - height / 2,
                      width: max(0, bounds.width - 2 * horizontalInset), height: height)
    }
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: contentRect(cellFrame), in: controlView)
    }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: contentRect(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: contentRect(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

final class CaptureAlignedLabel: NSTextField {
    init(caption: String) {
        super.init(frame: .zero); cell = CaptureCenteredTextCell(textCell: caption)
        stringValue = caption; isEditable = false; isSelectable = false
        isBezeled = false; isBordered = false; drawsBackground = false
        cell?.usesSingleLineMode = true
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
}

final class CapturePanelField: NSTextField {
    override var allowsVibrancy: Bool { false }
    convenience init(input: String) { self.init(frame: .zero); stringValue = input }
    override init(frame: NSRect) {
        super.init(frame: frame)
        let centered = CaptureCenteredTextCell(textCell: ""); centered.horizontalInset = 7; centered.usesSingleLineMode = true; centered.isScrollable = true
        cell = centered; isEditable = true; isSelectable = true; textColor = .labelColor
        isBezeled = false; isBordered = false; drawsBackground = false
        focusRingType = .default; wantsLayer = true; layer?.cornerRadius = 7; layer?.borderWidth = 0.7
        updateColors()
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        }
    }
}
