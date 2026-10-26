import AppKit
import SwiftUI
import CaptureCore

@MainActor
final class ThumbnailController {
    private var panel: NSPanel?
    private var timer: Timer?
    private var deadline: Date?
    private var remaining: TimeInterval = 6
    private var manualDismissal = false
    private var hover = false
    private var holdCount = 0
    private var id: UUID?
    private var observers: [NSObjectProtocol] = []
    private var trackingMenus: Set<ObjectIdentifier> = []
    var frame: CGRect? { panel?.frame }
    var isVisible: Bool { panel?.isVisible == true }
    var hasScheduledDismissal: Bool { timer?.isValid == true }
    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.panel != nil, let menu = notification.object as? NSMenu,
                      self.trackingMenus.insert(ObjectIdentifier(menu)).inserted else { return }
                self.pause()
            }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let menu = notification.object as? NSMenu,
                      self.trackingMenus.remove(ObjectIdentifier(menu)) != nil else { return }
                self.resume()
            }
        })
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    func show(document: CaptureDocument, screen: NSScreen?, app: AppController) {
        dismiss()
        id = document.id
        let panel = ThumbnailPanel(contentRect: CGRect(x: 0, y: 0, width: 326, height: 260),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let view = ThumbnailView(document: document, app: app, onHover: { [weak self] value in self?.setHover(value) },
                                 onClose: { [weak self] in self?.dismiss() })
        let hosting = NSHostingView(rootView: view)
        panel.contentView = hosting
        let size = hosting.fittingSize
        let bounds = (screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let options = app.store.preferences.presentation ?? PresentationOptions()
        let panelSize = CGSize(width: 326, height: max(220, size.height))
        panel.setFrame(CGRect(origin: options.corner.origin(in: bounds, size: panelSize), size: panelSize), display: true)
        self.panel = panel
        panel.orderFrontRegardless()
        manualDismissal = options.thumbnailSeconds == 0; remaining = Double(options.thumbnailSeconds); hover = false; holdCount = 0; schedule()
    }
    func dismiss() {
        timer?.invalidate(); timer = nil; deadline = nil
        panel?.orderOut(nil); panel?.close(); panel = nil; id = nil
        trackingMenus.removeAll(); holdCount = 0
    }
    func pause() { holdCount += 1; pauseTimer() }
    func resume() { holdCount = max(0, holdCount - 1); if holdCount == 0 && !hover { schedule() } }
    private func setHover(_ value: Bool) {
        guard hover != value else { return }
        hover = value
        if value { pauseTimer() } else if holdCount == 0 { schedule() }
    }
    private func pauseTimer() {
        if timer != nil, let deadline { remaining = max(0.25, deadline.timeIntervalSinceNow) }
        timer?.invalidate(); timer = nil
    }
    private func schedule() {
        guard panel != nil, !manualDismissal else { return }
        timer?.invalidate()
        deadline = Date().addingTimeInterval(remaining)
        timer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }
}

private final class ThumbnailPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct ThumbnailView: View {
    @ObservedObject var document: CaptureDocument
    @ObservedObject var app: AppController
    var onHover: (Bool) -> Void
    var onClose: () -> Void
    var body: some View {
        VStack(spacing: 10) {
            Button { app.showEditor(document) } label: {
                if let image = document.copiedImage ?? document.preview {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                        .frame(maxWidth: .infinity, minHeight: 110, maxHeight: 182)
                        .background(CaptureTheme.canvas).clipShape(RoundedRectangle(cornerRadius: 11))
                } else { ProgressView().frame(height: 150).frame(maxWidth: .infinity) }
            }.buttonStyle(.plain).help("打开标注和美化；也可拖动图片分享").onDrag { document.itemProvider() }
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(document.copyLabel).lineLimit(1)
                Spacer(minLength: 4)
                Text(document.copiedDimensions).monospacedDigit().foregroundStyle(.tertiary)
            }.font(.system(size: 10.5)).padding(.horizontal, 4)
            HStack(spacing: 5) {
                Button { app.showEditor(document) } label: { Label("编辑", systemImage: "pencil").frame(maxWidth: .infinity) }
                    .buttonStyle(CaptureActionStyle(primary: true))
                Button { app.save(document) } label: { Label("保存", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity) }
                Button { app.pin(document) } label: { Image(systemName: "pin").frame(width: 12, height: 14) }.help("置顶参考").accessibilityLabel("置顶参考图").disabled(app.pinning)
                Button { app.recognize(document) } label: { Image(systemName: "text.viewfinder").frame(width: 12, height: 14) }.help("提取文字").accessibilityLabel("提取文字")
                Menu {
                    Button("复制当前截图") { Task { await app.copy(document, originalOnly: false) } }
                    Button("复制原图") { Task { await app.copy(document, originalOnly: true) } }
                    Button("保存原图…") { app.save(document, originalOnly: true) }
                } label: { Image(systemName: "ellipsis").frame(width: 12, height: 14) }.menuIndicator(.hidden).fixedSize().accessibilityLabel("更多截图操作")
                Button(action: onClose) { Image(systemName: "xmark").frame(width: 12, height: 14) }.help("收起，可从最近截图找回").accessibilityLabel("收起截图缩略图")
            }.buttonStyle(CaptureActionStyle()).controlSize(.small).font(.system(size: 12))
        }.padding(10).frame(width: 326).background(CaptureTheme.chrome, in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(CaptureTheme.border))
            .onHover(perform: onHover)
    }
}
