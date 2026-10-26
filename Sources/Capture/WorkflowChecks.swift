import AppKit
import SwiftUI
import CaptureCore

/// Model, pixels, isolated persistence and offscreen AppKit views. Does not claim end-to-end user acceptance.
@MainActor enum WorkflowChecks {
    static func run(app: AppController, board: NSPasteboard, directory: URL) async throws -> [String] {
        func require(_ value: Bool,_ message: String) throws { if !value { throw DeveloperChecks.CheckFailure(message) } }
        var checks: [String] = []
        let image = SampleImage.make(width:1200,height:750)
        let doc = CaptureDocument(image:image,style:StylePreset.builtIns[8].style,useStyle:true)
        var pen = Annotation(kind:.pen,start:UnitPoint(0.1,0.3),end:UnitPoint(0.8,0.4))
        pen.points = [UnitPoint(0.1,0.3),UnitPoint(0.2,0.2),UnitPoint(0.6,0.5),UnitPoint(0.8,0.4)]
        doc.addAnnotation(pen); doc.undo(); try require(doc.edits.annotations.isEmpty,"手绘没有按一笔撤销")
        doc.redo(); try require(doc.edits.annotations == [pen],"手绘重做丢失路径")
        doc.rotate(); doc.flip(); let transformed = try await doc.rendered(contentOnly:true)
        try require(transformed.width == 750 && transformed.height == 1200,"手绘变换尺寸错误")
        doc.filename = "演示 · 极光"; doc.favorite = true
        let project = try await doc.projectSnapshot(), data = try await Task.detached { try project.encoded() }.value
        let restored = try await Task.detached { try CaptureProject.decode(data) }.value
        let reopened = CaptureDocument.restore(restored,image:try restored.image())
        try require(reopened.edits == doc.edits && reopened.favorite && reopened.filename == doc.filename,"项目恢复丢失编辑或元数据")
        checks += ["TC-PROJ-native-roundtrip", "TC-EDIT-05-pen-single-undo-transform"]
        doc.showOriginal = true
        let content = try await doc.rendered(scale:1)
        try require(content.width != image.width,"原图对比影响正常成品")
        let exportDirectory = directory.appendingPathComponent("export-fixtures")
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        for scale in [0.5,1.0,2.0] {
            doc.outputScale = scale
            let expected = try await doc.rendered()
            for format in ImageFormat.allCases {
                doc.outputFormat = format
                let export = try await app.prepareExport(doc)
                let decoded = try StyleCompositor.decode(export.data)
                try require(decoded.width == expected.width && decoded.height == expected.height,"复制导出倍率不一致")
                let url = exportDirectory.appendingPathComponent("export-\(scale).\(format.fileExtension)")
                try await app.writeExport(export, to: url, document: doc)
                try require(try Data(contentsOf: url) == export.data, "后台导出落盘内容不一致")
            }
            await app.copy(doc)
            try require(try board.data(forType:.png) == StyleCompositor.encode(expected),"复制没有使用当前成品")
        }
        doc.outputScale = 1; doc.outputFormat = .png; doc.showOriginal = false
        checks += ["TC-OUT-02-export-copy-scales-formats", "TC-OUT-01-share-render-source-boundary"]
        let previousDirectory = app.store.preferences.saveDirectory
        doc.message = nil
        do {
            let export = try await app.prepareExport(doc)
            try await app.writeExport(export, to: exportDirectory.appendingPathComponent("missing-parent/output.png"), document: doc)
            throw DeveloperChecks.CheckFailure("不存在的输出目录被错误记录为保存成功")
        } catch is DeveloperChecks.CheckFailure { throw DeveloperChecks.CheckFailure("无效导出位置未被拒绝") }
        catch {
            try require(app.store.preferences.saveDirectory == previousDirectory && doc.message == nil, "写盘失败却修改了保存位置或成功提示")
        }
        checks.append("TC-OUT-02-background-write-failure-retains-state")
        let library = app.library
        var options = HistoryOptions(); options.enabled = true; library.configure(options)
        app.remember(doc); await library.flush()
        try require(library.entries.contains(where:{$0.id == doc.id}),"启用本地历史后没有保存项目")
        let persisted = try await library.read(doc.id)
        try require(persisted.name == doc.filename && persisted.favorite,"历史元数据错误")
        let thumb = await library.thumbnail(doc.id); try require(thumb != nil,"历史缩略图未生成")
        doc.filename = "搜索用名称"; await library.flush()
        try require(library.entries.contains(where:{$0.name == "搜索用名称"}),"重命名未持久化")
        checks += ["TC-LIB-02-native-persist-reload", "TC-LIB-07-native-name-favorite-metadata"]
        let queued = CaptureDocument(image:image,style:CaptureStyle(),useStyle:false); app.remember(queued)
        options.enabled = false; library.configure(options)
        try await Task.sleep(for:.milliseconds(650))
        try require(!library.entries.contains(where:{$0.id == queued.id}),"关闭历史后排队项目仍保存")
        options.enabled = true; library.configure(options); library.schedule(queued); library.clear()
        try await Task.sleep(for:.milliseconds(750))
        try require(library.entries.isEmpty,"清空后旧任务复活项目")
        checks += ["TC-LIB-08-disable-cancels-queued-save", "TC-LIB-08-clear-cancels-queued-save"]
        options.enabled = false; library.configure(options)
        let thumbnail = ThumbnailController(); defer { thumbnail.dismiss() }
        let before = board.changeCount
        for corner in ThumbnailCorner.allCases {
            var presentation = PresentationOptions(); presentation.corner = corner; presentation.thumbnailSeconds = 0
            app.store.update { $0.presentation = presentation }
            thumbnail.show(document:doc,screen:NSScreen.main,app:app)
            try require(!thumbnail.hasScheduledDismissal,"手动关闭模式仍启动计时器")
            if let frame = thumbnail.frame, let screen = NSScreen.main { try require(screen.visibleFrame.contains(frame),"浮层超出屏幕") }
            thumbnail.pause(); thumbnail.resume(); try require(!thumbnail.hasScheduledDismissal,"手动模式恢复后错误倒计时")
        }
        thumbnail.dismiss(); app.restoreThumbnail()
        try require(board.changeCount == before,"恢复缩略图修改了剪贴板")
        app.store.update { $0.presentation = PresentationOptions() }
        checks += ["TC-UX-02-thumbnail-four-corners-manual", "TC-UX-02-restore-keeps-clipboard"]
        let pins = PinController(); pins.show(image,document:doc,app:app); pins.show(image,document:doc,app:app)
        pins.enableClickThrough(); try require(!pins.allInteractive,"穿透未生效")
        pins.restoreInteraction(); try require(pins.allInteractive,"穿透无法恢复")
        pins.closeAll(); try require(pins.count == 0,"关闭置顶未释放窗口")
        checks.append("TC-UX-03-pin-clickthrough-recovery")
        let collage = CollageModel(images:[image,image,image],names:["一","二","三"])
        let third = collage.items[2].id; collage.move(third,offset:-1); collage.move(third,offset:-1)
        try require(collage.items.first?.name == "三","拼图排序失效")
        collage.remove(collage.items[1].id); try require(collage.items.count == 2,"拼图移除失效")
        collage.options.direction = .grid; collage.refresh()
        for _ in 0..<60 { if !collage.rendering { break }; try await Task.sleep(for:.milliseconds(50)) }
        try require(collage.preview != nil && collage.canGenerate,"拼图预览失败")
        let result: CGImage = await withCheckedContinuation { continuation in collage.generate { continuation.resume(returning:$0) } }
        try require(result.width == 2416 && result.height == 750,"拼图生成与布局不一致")
        checks.append("TC-JOIN-04-reorder-remove-generate")
        app.showHelp(); let help = app.helpWindow; help?.close(); app.showHelp()
        try require(app.helpWindow === help && help?.isVisible == true,"帮助未复用可用窗口")
        help?.close(); checks.append("TC-UX-05-help-reopen")
        doc.removeEdits(); doc.filename = "周末随手记"; doc.favorite = true
        doc.addAnnotation(Annotation(kind:.arrow,start:UnitPoint(0.15,0.72),end:UnitPoint(0.43,0.53),color:RGBColor(hex:"A073DF"),lineWidth:4))
        await app.copy(doc)
        for _ in 0..<60 { if doc.preview != nil && !doc.rendering { break }; try await Task.sleep(for:.milliseconds(50)) }
        for tab in EditorTab.allCases {
            try await DeveloperChecks.snapshot(EditorView(document:doc,store:app.store,app:app,initialTab:tab),name:"v030-editor-\(tab.rawValue).png",width:1120,height:760,appearance:.light,directory:directory)
        }
        try await DeveloperChecks.snapshot(EditorView(document:doc,store:app.store,app:app),name:"v030-editor-dark.png",width:900,height:640,appearance:.dark,directory:directory)
        try await DeveloperChecks.snapshot(PixelPreview(document:doc,zoom:1),name:"v030-pixel100.png",width:700,height:500,appearance:.light,directory:directory)
        try await DeveloperChecks.snapshot(SettingsView(store:app.store,app:app),name:"v030-settings.png",width:580,height:720,appearance:.light,directory:directory)
        try await DeveloperChecks.snapshot(SettingsView(store:app.store,app:app),name:"v030-settings-minimum-dark.png",width:520,height:450,appearance:.dark,directory:directory)
        for section in 1...3 {
            try await DeveloperChecks.snapshot(SettingsView(store: app.store, app: app, initialSection: section), name: "v040-settings-\(section).png", width: 580, height: 720, appearance: .light, directory: directory)
        }
        try await DeveloperChecks.snapshot(CollageView(model:collage,onCreate:{_ in}),name:"v030-collage.png",width:960,height:680,appearance:.light,directory:directory)
        try await DeveloperChecks.snapshot(HelpView(store:app.store),name:"v030-help.png",width:640,height:650,appearance:.light,directory:directory)
        try await DeveloperChecks.snapshot(RecentCapturesView(app:app),name:"v030-library.png",width:740,height:550,appearance:.light,directory:directory)
        try await DeveloperChecks.snapshot(PresetsView(store:app.store,app:app,source:image),name:"v030-presets.png",width:920,height:640,appearance:.light,directory:directory)
        try await DeveloperChecks.snapshot(MenuView(store:app.store,app:app),name:"v030-menu.png",width:324,height:590,appearance:.light,directory:directory)
        try await DeveloperChecks.snapshot(WelcomeView(store:app.store,app:app),name:"v030-welcome.png",width:530,height:540,appearance:.light,directory:directory)
        try await DeveloperChecks.snapshot(ThumbnailView(document:doc,app:app,onHover:{_ in},onClose:{}),name:"v030-thumbnail.png",width:326,height:270,appearance:.light,directory:directory)
        try await DeveloperChecks.snapshot(PinnedImageView(image:image,copy:{true},close:{}),name:"v030-pin.png",width:600,height:420,appearance:.light,directory:directory)
        try await DeveloperChecks.snapshot(RecognitionView(document:doc,pasteboard:board),name:"v030-ocr.png",width:640,height:540,appearance:.light,directory:directory,delayNanoseconds:2_000_000_000)
        let scrolling = ScrollingCaptureController(); scrolling.frames = 3; scrolling.status = "缓慢向下滚动，完成后点「结束并复制」。"
        try await DeveloperChecks.snapshot(ScrollingCaptureView(controller:scrolling),name:"v030-scrolling.png",width:370,height:160,appearance:.light,directory:directory)
        try await DeveloperChecks.snapshot(CountdownView(seconds:3,cancel:{}),name:"v030-countdown.png",width:270,height:105,appearance:.light,directory:directory)
        checks.append("TC-UX-04-offscreen-native-layouts")
        try await presetSearchRemainsVisible(app: app, image: image)
        checks.append("TC-PRE-05-search-visible-after-default-scroll")
        return checks
    }

    private static func presetSearchRemainsVisible(app: AppController, image: CGImage) async throws {
        let previous = app.store.preferences.defaultPresetID
        app.store.setDefaultPreset(StylePreset.builtIns.last!.id)
        defer { app.store.update { $0.defaultPresetID = previous } }
        let hosting = NSHostingView(rootView: PresetsView(store: app.store, app: app, source: image))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 820, height: 570), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        func fields(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
        }
        guard let search = fields(hosting).first(where: { $0.placeholderString == "搜索预设" }),
              search.visibleRect.height > 10, search.visibleRect.width > 50 else {
            throw DeveloperChecks.CheckFailure("默认预设滚动后搜索框不可见")
        }
    }
}
