import AppKit
import SwiftUI
import Combine
import CaptureCore

@MainActor
final class ScrollingCaptureController: ObservableObject {
    @Published var frames = 0
    @Published var status = "正在准备首帧…"
    private var panel: NSPanel?
    private var task: Task<Void, Never>?
    private var image: CGImage?
    private var completion: ((CGImage?) -> Void)?
    var isActive: Bool { completion != nil }
    func begin(selection: ScreenSelection, includeCursor: Bool = false, completion: @escaping (CGImage?) -> Void) {
        self.completion = completion; frames = 0; image = nil; status = "正在准备首帧…"
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 370, height: 160), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "滚动长截图"; panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ScrollingCaptureView(controller: self))
        let bounds = selection.screen.visibleFrame
        panel.setFrameOrigin(CGPoint(x: bounds.maxX - 390, y: bounds.minY + 24))
        self.panel = panel; panel.orderFrontRegardless()
        task = Task {
            var previous: CGImage?
            while !Task.isCancelled {
                do {
                    let frame = try await ScreenCaptureService.capture(displayID: selection.displayID, selection: selection.rectangle, backingScale: selection.scale, includeCursor: includeCursor)
                    guard !Task.isCancelled else { return }
                    if let reference = previous, let accumulated = image {
                        let result = try await Task.detached(priority: .userInitiated) { () -> (CGImage?, String) in
                            switch ImageStitcher.match(previous: reference, next: frame) {
                            case .unchanged: return (nil, "缓慢向下滚动，完成后点「结束并复制」。")
                            case .noMatch: return (nil, "重叠不足或内容变化，请向上回滚一点，再缓慢向下；选区应避开固定顶栏。")
                            case .append(let rows): return (try ImageStitcher.append(accumulated, frame: frame, newRows: rows), "已拼接，继续缓慢向下滚动。")
                            }
                        }.value
                        guard !Task.isCancelled else { return }
                        status = result.1
                        if let next = result.0 { image = next; frames += 1 }
                        // An unmatched frame must not replace the last matching reference.
                        if result.0 != nil { previous = frame }
                    } else {
                        image = frame; previous = frame; frames = 1
                        status = "在选区内缓慢向下滚动，每次不超过半屏。"
                    }
                    try await Task.sleep(nanoseconds: 650_000_000)
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled else { return }
                    status = "已暂停：\(error.localizedDescription) 可结束并保留已捕获内容。"; return
                }
            }
        }
    }
    func finish() { complete(image) }
    func cancel() { complete(nil) }
    private func complete(_ result: CGImage?) {
        guard let completion else { return }
        self.completion = nil; task?.cancel(); task = nil
        panel?.orderOut(nil); panel?.close(); panel = nil; image = nil
        completion(result)
    }
}

struct ScrollingCaptureView: View {
    @ObservedObject var controller: ScrollingCaptureController
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label("手动滚动 · 自动拼接", systemImage: "scroll").font(.system(size: 13, weight: .semibold)); Spacer(); Text("\(controller.frames) 帧").font(.system(size: 11)).foregroundStyle(.secondary) }
            Text(controller.status).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("取消") { controller.cancel() }
                Spacer()
                Button(controller.frames > 1 ? "结束并复制" : "结束并复制首帧") { controller.finish() }.buttonStyle(CaptureActionStyle(primary: true)).disabled(controller.frames == 0)
            }
        }.padding(18).frame(width: 370).buttonStyle(CaptureActionStyle()).tint(CaptureTheme.accent)
    }
}

@MainActor
final class CountdownController {
    private var panel: NSPanel?
    func show(seconds: Int, screen: NSScreen?, cancel: @escaping () -> Void) {
        if panel == nil {
            let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 270, height: 105), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.isOpaque = false; panel.backgroundColor = .clear
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let bounds = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            panel.setFrameOrigin(CGPoint(x: bounds.midX - 135, y: bounds.maxY - 150))
            self.panel = panel
        }
        panel?.contentView = NSHostingView(rootView: CountdownView(seconds: seconds, cancel: cancel))
        panel?.orderFrontRegardless()
    }
    func dismiss() { panel?.orderOut(nil); panel?.close(); panel = nil }
}

struct CountdownView: View {
    let seconds: Int
    let cancel: () -> Void
    var body: some View {
        VStack(spacing: 9) {
            Text("\(seconds) 秒后截图").font(.system(size: 21, weight: .medium)).monospacedDigit()
            Button("取消 · 或再按一次截图快捷键", action: cancel).buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(width: 270, height: 105).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
