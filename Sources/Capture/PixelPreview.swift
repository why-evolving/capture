import AppKit
import SwiftUI
import CaptureCore

private typealias PixelState<Value> = SwiftUI.State<Value>
private struct PixelKey: Equatable { let style: CaptureStyle; let enabled: Bool; let edits: ImageEdits; let original: Bool }
struct PixelPreview: View {
    @ObservedObject var document: CaptureDocument
    let zoom: Double
    @PixelState private var image: CGImage?
    @PixelState private var error: String?
    private var key: PixelKey { PixelKey(style:document.style,enabled:document.useStyle,edits:document.edits,original:document.showOriginal) }
    var body: some View {
        ZStack {
            if let image { PixelScrollView(image:image,zoom:zoom) }
            else if let error { Text(error).foregroundStyle(.orange).padding() }
            else { ProgressView("载入原始像素…") }
        }.task(id:key) {
            image = nil; error = nil
            do {
                let result = try await document.rendered(originalOnly:document.showOriginal,scale:1)
                if !Task.isCancelled { image = result }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }.onDrag { document.itemProvider() }
    }
}
struct PixelScrollView: NSViewRepresentable {
    let image: CGImage
    let zoom: Double
    func makeNSView(context: Context) -> PixelScrollContainer {
        let scroll = PixelScrollContainer(); scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
        scroll.drawsBackground = false; scroll.autohidesScrollers = true
        scroll.documentView = PixelImageView(); scroll.setAccessibilityLabel("原始像素预览，可横向和纵向滚动")
        return scroll
    }
    func updateNSView(_ view: PixelScrollContainer, context: Context) { view.image = image; view.zoom = zoom; view.updateImage() }
}
final class PixelScrollContainer: NSScrollView {
    var image: CGImage?
    var zoom = 1.0
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateImage() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateImage() }
    func updateImage() {
        guard let image, let canvas = documentView as? PixelImageView else { return }
        canvas.image = image
        canvas.frame = CGRect(origin:.zero,size:ViewportGeometry.pointSize(pixels:CGSize(width:image.width,height:image.height),zoom:zoom,backingScale:Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)))
        canvas.needsDisplay = true
    }
}
final class PixelImageView: NSView {
    var image: CGImage?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); context.interpolationQuality = .none
        context.translateBy(x:0,y:bounds.height); context.scaleBy(x:1,y:-1); context.draw(image,in:bounds); context.restoreGState()
    }
}

struct ShareImageButton: NSViewRepresentable {
    @ObservedObject var document: CaptureDocument
    func makeCoordinator() -> Coordinator { Coordinator(document:document) }
    func makeNSView(context: Context) -> NSButton {
        let button = CapturePanelButton(symbol:NSImage(systemSymbolName:"square.and.arrow.up",accessibilityDescription:"分享当前成品")!,target:context.coordinator,action:#selector(Coordinator.share(_:)))
        button.title = ""; button.setAccessibilityLabel("分享当前成品"); button.toolTip = "系统分享 · 当前编辑结果"; return button
    }
    func updateNSView(_ view: NSButton, context: Context) { context.coordinator.document = document }
    @MainActor final class Coordinator: NSObject {
        var document: CaptureDocument
        var picker: NSSharingServicePicker?
        init(document:CaptureDocument) { self.document = document }
        @objc func share(_ sender: NSButton) {
            guard sender.isEnabled else { return }; sender.isEnabled = false
            Task {
                defer { sender.isEnabled = true }
                do {
                    let image = try await document.rendered()
                    guard sender.window?.isVisible == true else { return }
                    let item = NSImage(cgImage:image,size:CGSize(width:image.width,height:image.height))
                    picker = NSSharingServicePicker(items:[item]); picker?.show(relativeTo:sender.bounds,of:sender,preferredEdge:.minY)
                } catch { document.message = error.localizedDescription }
            }
        }
    }
}
