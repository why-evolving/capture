import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CaptureCore

extension AppController {
    func openProject(_ url: URL) {
        Task {
            do {
                let (project, image) = try await Task.detached(priority: .userInitiated) { let p = try CaptureProject.read(url); return (p, try p.image()) }.value
                acceptProject(project, image: image)
            } catch { store.errorMessage = error.localizedDescription; showOperationError(error) }
        }
    }
    func openLibrary(_ id: UUID) {
        if let document = existingDocument(id) { showEditor(document); return }
        Task {
            do {
                let project = try await library.read(id)
                let image = try await Task.detached(priority: .userInitiated) { try project.image() }.value
                acceptProject(project, image: image)
            } catch { showOperationError(error) }
        }
    }
    private func acceptProject(_ project: CaptureProject, image: CGImage) {
        if let existing = existingDocument(project.id) { showEditor(existing); return }
        let document = CaptureDocument.restore(project, image: image)
        document.onStyleChange = { [weak store] in store?.useStyle($0) }
        remember(document); showEditor(document)
        document.message = "已恢复可编辑项目；原图、标注与样式均已保留。"
    }
    func saveProject(_ document: CaptureDocument) {
        guard !saving, !choosingFiles, !busy else { return }; saving = true
        let panel = NSSavePanel(); activeSavePanel = panel; panel.title = "保存可编辑项目"
        panel.message = "项目包含未遮挡的原图和全部编辑信息。对外分享请使用 PNG / JPEG。"
        panel.allowedContentTypes = [UTType(filenameExtension: "capture") ?? .data]
        panel.nameFieldStringValue = document.filename.replacingOccurrences(of: "/", with: "-") + ".capture"
        panel.begin { response in
            self.activeSavePanel = nil
            guard response == .OK, let url = panel.url else { self.saving = false; return }
            Task {
                defer { self.saving = false }
                do {
                    let project = try await document.projectSnapshot()
                    try await Task.detached(priority: .utility) { try project.write(url) }.value
                    document.message = "项目已保存，可重新打开继续编辑。"
                } catch { document.message = error.localizedDescription; self.showOperationError(error) }
            }
        }
    }
    func importPresets() {
        let panel = NSOpenPanel(); panel.title = "导入样式预设"; panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard beginFileChoice(panel) else { return }
        panel.begin { response in
            self.endFileChoice()
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    let data = try await Task.detached(priority: .utility) { try BoundedFile.read(url, limit: PresetArchive.maximumBytes) }.value
                    let imported = try PresetArchive.imported(data, existing: self.store.presets)
                    self.store.update { $0.customPresets.append(contentsOf: imported) }
                } catch { self.showOperationError(error) }
            }
        }
    }
    func exportPresets(_ presets: [StylePreset]) {
        guard !saving, !choosingFiles, !busy else { return }; saving = true
        let panel = NSSavePanel(); panel.title = "导出预设"; panel.nameFieldStringValue = "Capture-Presets.json"; panel.allowedContentTypes = [.json]
        activeSavePanel = panel
        panel.message = "只包含样式参数，不包含截图、快捷键或其他个人设置。"
        panel.begin { response in
            self.activeSavePanel = nil
            guard response == .OK, let url = panel.url else { self.saving = false; return }
            Task { defer { self.saving = false }; do { try await Task.detached(priority: .utility) { try PresetArchive(presets: presets).encoded().write(to: url, options: .atomic) }.value } catch { self.showOperationError(error) } }
        }
    }
    func renameDocument(_ document: CaptureDocument) {
        let alert = NSAlert(); alert.messageText = "重命名截图"; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        let field = CapturePanelField(input: document.filename); field.frame = CGRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field; alert.window.initialFirstResponder = field
        while alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty && name.count <= 200 { document.filename = name; return }
            alert.informativeText = "请输入 1–200 个字符。"
        }
    }
    func showCollage(images: [CGImage], names: [String]) {
        collageWindow?.close()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 960, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "拼图工作台"; window.minSize = CGSize(width: 780, height: 540); window.isReleasedWhenClosed = false
        let model = CollageModel(images: images, names: names)
        window.contentView = NSHostingView(rootView: CollageView(model: model, onCreate: { [weak self, weak window] image in
            guard let self else { return }
            let document = CaptureDocument(image: image, style: self.store.captureStyle, useStyle: false)
            document.filename = "拼图-" + DateFormatter.captureName.string(from: Date())
            self.remember(document); self.showEditor(document); window?.close()
        }))
        collageWindow = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func showHelp() {
        if let helpWindow { helpWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Capture 使用指南"; window.minSize = CGSize(width: 500, height: 440); window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HelpView(store: store)); helpWindow = window
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func showOperationError(_ error: Error) { let alert = NSAlert(error: error); alert.runModal() }
}
