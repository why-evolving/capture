import Testing
import Foundation
import CoreGraphics
@testable import CaptureCore

private func solid(_ color: String = "FFFFFF", width: Int = 100, height: Int = 80) throws -> CGImage {
    let c = try #require(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
    c.setFillColor(RGBColor(hex:color).cgColor); c.fill(CGRect(x:0,y:0,width:width,height:height))
    return try #require(c.makeImage())
}
private func pixel(_ image:CGImage,_ x:Int,_ y:Int) throws -> [Int] {
    let cropped = try #require(image.cropping(to:CGRect(x:x,y:y,width:1,height:1)))
    let c = try #require(CGContext(data:nil,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
    c.draw(cropped,in:CGRect(x:0,y:0,width:1,height:1))
    let p = try #require(c.data?.assumingMemoryBound(to:UInt8.self)); return (0..<3).map { Int(p[$0]) }
}
private func project(name:String = "测试项目", date:Date = Date()) throws -> CaptureProject {
    CaptureProject(createdAt:date,modifiedAt:date,name:name,originalPNG:try StyleCompositor.encode(solid()),style:CaptureStyle(),useStyle:true)
}
private func temp() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-tests-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true); return url
}
@Test("TC-PROJ-01 项目往返保留原图、编辑和元数据") func projectRoundTrip() throws {
    var p = try project(); p.favorite = true; p.edits.quarterTurns = 1; p.edits.annotations = [Annotation(kind:.redact,start:UnitPoint(0.1,0.1),end:UnitPoint(0.5,0.5))]
    let restored = try CaptureProject.decode(p.encoded())
    #expect(restored == p); #expect(try restored.image().width == 100)
    #expect(try pixel(EditedImageRenderer.render(restored.image(),edits:restored.edits),60,20)[0] < 30)
}
@Test("TC-PROJ-02 未知版本、非法编辑及缺失原图拒绝") func invalidProject() throws {
    var p = try project(); p.version = 99; #expect(throws:(any Error).self) { try p.encoded() }
    p.version = 1; p.edits.crop.width = -1; #expect(throws:(any Error).self) { try p.encoded() }
    p.edits = ImageEdits(); p.originalPNG = Data(); #expect(throws:(any Error).self) { try p.encoded() }
    p = try project(); p.name = "  "; #expect(!p.isValid)
}
@Test("资源校验：有界文件读取") func boundedFile() throws {
    let dir = try temp(); defer { try? FileManager.default.removeItem(at:dir) }
    let file = dir.appendingPathComponent("too-large"); try Data(repeating:0,count:1025).write(to:file)
    #expect(throws:(any Error).self) { try BoundedFile.read(file,limit:1024) }
    #expect(try BoundedFile.read(file,limit:1025).count == 1025)
    #expect(throws:(any Error).self) { try CaptureProject.decode(Data("{}".utf8)) }
}
@Test("隐私边界：原图保存不受遮挡影响，成品保留遮挡") func projectPrivacyBoundary() throws {
    var p = try project(); p.edits.annotations = [Annotation(kind:.redact,start:UnitPoint(0.1,0.1),end:UnitPoint(0.8,0.8))]
    #expect(try pixel(p.image(),30,30) == [255,255,255])
    #expect(try pixel(EditedImageRenderer.render(p.image(),edits:p.edits),30,30)[0] < 30)
}
@Test("TC-PRE-01/02 预设导入新ID、重名后缀、参数往返") func presetImport() throws {
    let p = StylePreset.builtIns[0], data = try PresetArchive(presets:[p,p]).encoded()
    let result = try PresetArchive.imported(data,existing:StylePreset.builtIns)
    #expect(result.count == 2); #expect(result[0].name == "暮光 (2)"); #expect(result[1].name == "暮光 (3)")
    #expect(result[0].style == p.style); #expect(!result[0].isBuiltIn); #expect(result[0].id != result[1].id && result[0].id != p.id)
}
@Test("TC-PRE-03/04 整包校验、版本及数量限制") func invalidPresetArchive() throws {
    var archive = PresetArchive(presets:[StylePreset.builtIns[0]]); archive.version = 2
    #expect(throws:(any Error).self) { try PresetArchive.imported(JSONEncoder().encode(archive),existing:[]) }
    archive.version = 1; archive.presets.append(StylePreset(name:"",style:CaptureStyle()))
    #expect(throws:(any Error).self) { try PresetArchive.imported(JSONEncoder().encode(archive),existing:[]) }
    let hundred = (0..<100).map { StylePreset(name:"\($0)",style:CaptureStyle()) }
    #expect(throws:(any Error).self) { try PresetArchive.imported(PresetArchive(presets:[StylePreset.builtIns[0]]).encoded(),existing:hundred) }
    #expect(throws:(any Error).self) { try PresetArchive.imported(Data(repeating:0,count:PresetArchive.maximumBytes+1),existing:[]) }
}
@Test("TC-LIB-01/02 关闭默认与跨实例索引恢复") func libraryRoundTrip() throws {
    #expect(!HistoryOptions().enabled)
    let dir = try temp(); defer { try? FileManager.default.removeItem(at:dir) }
    let archive = LibraryArchive(directory:dir); var a = try project(); a.favorite = true
    let entries = try archive.save(a,retentionDays:7)
    #expect(entries.count == 1); #expect(entries[0].favorite)
    let reopened = LibraryArchive(directory:dir)
    #expect(try reopened.read(a.id) == a)
    let index = try Data(contentsOf:dir.appendingPathComponent("index.json"))
    #expect(!String(decoding:index,as:UTF8.self).contains("originalPNG"))
}
@Test("TC-LIB-03 数量与容量限制") func libraryLimits() throws {
    let dir = try temp(); defer { try? FileManager.default.removeItem(at:dir) }
    var archive = LibraryArchive(directory:dir); archive.maximumCount = 2
    let now = Date(), a = try project(name:"a",date:now.addingTimeInterval(-3)), b = try project(name:"b",date:now.addingTimeInterval(-2)), c = try project(name:"c",date:now)
    try archive.save(a,retentionDays:7); try archive.save(b,retentionDays:7)
    let list = try archive.save(c,retentionDays:7)
    #expect(list.map(\.name) == ["c","b"])
    #expect(!FileManager.default.fileExists(atPath:dir.appendingPathComponent(a.id.uuidString+".capture").path))
    archive.maximumBytes = list[0].bytes
    let pruned = try archive.prune(retentionDays:7)
    #expect(pruned.count == 1)
}
@Test("TC-LIB-04 保留时间边界") func libraryRetention() throws {
    let dir = try temp(); defer { try? FileManager.default.removeItem(at:dir) }
    let archive = LibraryArchive(directory:dir), now = Date(timeIntervalSince1970:1_800_000_000)
    let edge = try project(name:"edge",date:now.addingTimeInterval(-7*86400)), expired = try project(name:"expired",date:now.addingTimeInterval(-7*86400-1))
    try archive.save(expired,retentionDays:30,now:now); try archive.save(edge,retentionDays:30,now:now)
    #expect(try archive.prune(retentionDays:7,now:now).map(\.name) == ["edge"])
}

@Test("TC-LIB-03 无效保留策略在写盘前拒绝，已有项目不变") func invalidLibraryPolicyDoesNotWrite() throws {
    let dir = try temp(); defer { try? FileManager.default.removeItem(at: dir) }
    var archive = LibraryArchive(directory: dir)
    let original = try project(name: "保留的项目")
    try archive.save(original, retentionDays: 7)
    let indexBefore = try Data(contentsOf: dir.appendingPathComponent("index.json"))
    var changed = original; changed.name = "不能写入的更新"
    #expect(throws: (any Error).self) { try archive.save(changed, retentionDays: 0) }
    #expect(try archive.read(original.id) == original)
    #expect(try Data(contentsOf: dir.appendingPathComponent("index.json")) == indexBefore)
    archive.maximumCount = 0
    let extra = try project(name: "不能创建的项目")
    #expect(throws: (any Error).self) { try archive.save(extra, retentionDays: 7) }
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(extra.id.uuidString + ".capture").path))
}
@Test("TC-LIB-05/06 单项损坏隔离、清空保留无关文件") func libraryCorruptionAndClear() throws {
    let dir = try temp(); defer { try? FileManager.default.removeItem(at:dir) }
    let archive = LibraryArchive(directory:dir), good = try project(name:"good"), bad = try project(name:"bad")
    try archive.save(good,retentionDays:7); try archive.save(bad,retentionDays:7)
    try Data("broken".utf8).write(to:dir.appendingPathComponent(bad.id.uuidString+".capture"))
    #expect(throws:(any Error).self) { try archive.read(bad.id) }
    #expect(try archive.read(good.id).name == "good")
    let unrelated = dir.appendingPathComponent("my-notes.capture"); try Data("keep".utf8).write(to:unrelated)
    try archive.clear(); #expect(try archive.entries().isEmpty); #expect(FileManager.default.fileExists(atPath:unrelated.path))
}
@Test("TC-LIB-06 索引不接受外部路径作为身份") func libraryPathInjection() throws {
    let dir = try temp(); defer { try? FileManager.default.removeItem(at:dir) }
    try Data("[{\"id\":\"../../private\",\"name\":\"bad\",\"favorite\":false,\"createdAt\":0,\"modifiedAt\":0,\"bytes\":1}]".utf8).write(to:dir.appendingPathComponent("index.json"))
    #expect(throws:(any Error).self) { try LibraryArchive(directory:dir).entries() }
}
@Test("TC-EDIT-01 直线与多点路径实际着色") func lineAndPen() throws {
    let image = try solid(width:100,height:100)
    var edits = ImageEdits(), pen = Annotation(kind:.pen,start:UnitPoint(0.1,0.2),end:UnitPoint(0.8,0.8),color:RGBColor(hex:"FF0000"),lineWidth:4)
    pen.points = [UnitPoint(0.1,0.2),UnitPoint(0.8,0.2),UnitPoint(0.8,0.8)]
    edits.annotations = [pen,Annotation(kind:.line,start:UnitPoint(0.1,0.5),end:UnitPoint(0.5,0.5),color:RGBColor(hex:"0000FF"),lineWidth:4)]
    let result = try EditedImageRenderer.render(image,edits:edits)
    #expect(try pixel(result,40,20) == [255,0,0]); #expect(try pixel(result,80,50) == [255,0,0])
    #expect(try pixel(result,30,50) == [0,0,255]); #expect(try pixel(result,5,95) == [255,255,255])
}
@Test("TC-EDIT-02 路径边界及移动保持全路径") func penBounds() {
    var pen = Annotation(kind:.pen,start:UnitPoint(0.5,0.5),end:UnitPoint(0.5,0.6)); pen.points = [UnitPoint(0.1,0.2),UnitPoint(0.9,0.8)]
    #expect(abs(pen.bounds.width-0.8) < 0.00001); pen.move(dx:1,dy:1)
    #expect(abs(pen.points![1].x-1) < 0.00001)
    var edits = ImageEdits(); edits.annotations = [pen]; #expect(edits.isValid)
    edits.annotations[0].points = Array(repeating:UnitPoint(0.5,0.5),count:4096); #expect(edits.isValid)
    edits.annotations[0].points!.append(UnitPoint(0.5,0.5)); #expect(!edits.isValid)
    edits.annotations[0].points = [UnitPoint(.nan,0),UnitPoint(0,0)]; #expect(!edits.isValid)
}
@Test("TC-EDIT-03 聚光不恢复遮挡，马赛克不重读原图") func redactionRemainsPrivate() throws {
    var edits = ImageEdits(); edits.annotations = [Annotation(kind:.redact,start:UnitPoint(0.1,0.1),end:UnitPoint(0.9,0.9)),Annotation(kind:.pixelate,start:UnitPoint(0.2,0.2),end:UnitPoint(0.8,0.8)),Annotation(kind:.spotlight,start:UnitPoint(0.3,0.3),end:UnitPoint(0.7,0.7))]
    let result = try EditedImageRenderer.render(solid(width:100,height:100),edits:edits)
    #expect(try pixel(result,50,50)[0] < 30); #expect(try pixel(result,25,25)[0] < 20)
    #expect(try pixel(result,0,0)[0] > 100 && pixel(result,0,0)[0] < 140)
}
@Test("TC-EDIT-04 Retina像素视口") func pixelViewport() {
    #expect(ViewportGeometry.pointSize(pixels:CGSize(width:1200,height:800),zoom:1,backingScale:2) == CGSize(width:600,height:400))
    #expect(ViewportGeometry.pointSize(pixels:CGSize(width:1200,height:800),zoom:2,backingScale:2) == CGSize(width:1200,height:800))
    #expect(ViewportGeometry.pointSize(pixels:CGSize(width:1200,height:800),zoom:1,backingScale:1) == CGSize(width:1200,height:800))
}
@Test("TC-JOIN-01 纵横网格顺序与原图比例") func collageDirections() throws {
    let images = try [solid("FF0000",width:20,height:10),solid("00FF00",width:30,height:20),solid("0000FF",width:10,height:30)]
    for direction in CollageDirection.allCases {
        var options = CollageOptions(); options.direction = direction
        let layout = try CollageLayout.make(sizes:images.map { CGSize(width:$0.width,height:$0.height) },options:options)
        let output = try CollageLayout.render(images,options:options)
        for (index,frame) in layout.frames.enumerated() {
            #expect(frame.width == CGFloat(images[index].width)); #expect(frame.height == CGFloat(images[index].height))
            #expect(try pixel(output,Int(frame.midX),Int(frame.midY)) == [[255,0,0],[0,255,0],[0,0,255]][index])
        }
    }
}
@Test("TC-JOIN-02 间距与背景") func collageGap() throws {
    for gap in [0,80] {
        var options = CollageOptions(); options.gap = gap; options.background = RGBColor(hex:"F0A0B0")
        let result = try CollageLayout.render([solid(width:10,height:10),solid(width:10,height:10)],options:options)
        #expect(result.height == 20+gap)
        if gap > 0 { #expect(try pixel(result,5,20) == [240,160,176]) }
    }
}
@Test("TC-JOIN-03 拼图数量、尺寸与参数限制") func collageBounds() throws {
    var options = CollageOptions()
    #expect(throws:(any Error).self) { try CollageLayout.make(sizes:[],options:options) }
    #expect(throws:(any Error).self) { try CollageLayout.make(sizes:Array(repeating:CGSize(width:1,height:1),count:13),options:options) }
    #expect(throws:(any Error).self) { try CollageLayout.make(sizes:[CGSize(width:10000,height:10000),CGSize(width:10000,height:10000)],options:options) }
    options.gap = -1; #expect(throws:(any Error).self) { try CollageLayout.make(sizes:[CGSize(width:10,height:10),CGSize(width:10,height:10)],options:options) }
}
@Test("TC-STYLE-01 极光确定性及内容像素") func auroraPreservesPixels() throws {
    let source = try solid("1256AB",width:120,height:80); var style = CaptureStyle(); style.background = .aurora
    let a = try StyleCompositor.render(source,style:style), b = try StyleCompositor.render(source,style:style)
    #expect(try StyleCompositor.encode(a) == StyleCompositor.encode(b))
    #expect(try pixel(a,a.width/2,a.height/2) == pixel(source,60,40))
}
@Test("TC-STYLE-02 社交画布比例") func portraitRatios() throws {
    for ratio in [CanvasRatio.portrait,.story] {
        for size in [CGSize(width:721,height:451),CGSize(width:451,height:721)] {
            var style = CaptureStyle(); style.ratio = ratio
            let layout = try RenderLayout.make(source:size,style:style)
            #expect(abs(layout.canvasSize.width/layout.canvasSize.height-ratio.value!) < 0.003)
            #expect(layout.imageRect.size == size)
        }
    }
}
@Test("TC-STYLE-03 十二套有效预设") func builtInStyles() {
    #expect(StylePreset.builtIns.count >= 12); #expect(Set(StylePreset.builtIns.map(\.id)).count == StylePreset.builtIns.count)
    #expect(StylePreset.builtIns.allSatisfy { $0.style.isValid })
}
@Test("TC-UX-01 新旧界面设置兼容") func presentationPreferences() throws {
    var prefs = AppPreferences()
    #expect((prefs.presentation ?? PresentationOptions()).theme == .light)
    for corner in ThumbnailCorner.allCases {
        for seconds in [0,3,6,10] {
            for theme in AppTheme.allCases {
                var options = PresentationOptions(); options.corner = corner; options.thumbnailSeconds = seconds; options.theme = theme
                prefs.presentation = options
                let copy = try JSONDecoder().decode(AppPreferences.self,from:JSONEncoder().encode(prefs)); #expect(copy.isValid && copy.presentation == options)
            }
        }
    }
    prefs.presentation!.thumbnailSeconds = -1; #expect(!prefs.isValid)
    prefs.presentation = nil; #expect(try JSONDecoder().decode(AppPreferences.self,from:JSONEncoder().encode(prefs)).presentation == nil)
}
@Test("TC-UX-02 四角浮层位置") func thumbnailCorners() {
    let screen = CGRect(x:-1920,y:0,width:1920,height:1080), size = CGSize(width:326,height:260)
    let positions = ThumbnailCorner.allCases.map { $0.origin(in:screen,size:size) }
    #expect(Set(positions.map { "\($0.x),\($0.y)" }).count == 4)
    for p in positions { #expect(screen.contains(CGRect(origin:p,size:size))) }
}

@Test("TC-PROJ-01/04 所有项目编辑参数和成品完整往返") func completeProjectRoundTrip() throws {
    for appearance in WindowAppearance.allCases {
        var p = try project(); p.style.windowFrame = true; p.style.windowAppearance = appearance
        p.scale = 0.5; p.format = .jpeg; p.quality = 0.75
        p.edits.crop = UnitRect(x:0.1,y:0.1,width:0.8,height:0.8)
        p.edits.annotations = [Annotation(kind:.text,start:UnitPoint(0.1,0.1),end:UnitPoint(0.7,0.6),text:"中文 Test"),Annotation(kind:.redact,start:UnitPoint(0.2,0.2),end:UnitPoint(0.6,0.6))]
        let r = try CaptureProject.decode(p.encoded())
        let before = try StyleCompositor.render(EditedImageRenderer.render(p.image(),edits:p.edits),style:p.style,scale:p.scale)
        let after = try StyleCompositor.render(EditedImageRenderer.render(r.image(),edits:r.edits),style:r.style,scale:r.scale)
        #expect(r == p); #expect(try StyleCompositor.encode(before) == StyleCompositor.encode(after))
    }
}
@Test("TC-PROJ-02 截断JSON和字段类型错误") func projectJSONFailures() throws {
    let bytes = try project().encoded()
    #expect(throws:(any Error).self) { try CaptureProject.decode(bytes.dropLast(12)) }
    var object = try #require(JSONSerialization.jsonObject(with:bytes) as? [String:Any]); object["scale"] = "invalid"
    #expect(throws:(any Error).self) { try CaptureProject.decode(JSONSerialization.data(withJSONObject:object)) }
}
@Test("TC-PROJ-03 非法倍率、名称、JPEG质量拒绝") func projectMetadataBounds() throws {
    var p = try project(); p.scale = .nan; #expect(!p.isValid)
    p.scale = 10; #expect(!p.isValid); p.scale = 1
    p.name = String(repeating:"字",count:201); #expect(!p.isValid); p.name = "图"
    p.quality = 1.1; #expect(!p.isValid); p.quality = .infinity; #expect(!p.isValid)
}
@Test("TC-PROJ-05 项目总字节和伪PNG限制") func projectSizeLimits() throws {
    #expect(throws:(any Error).self) { try CaptureProject.decode(Data(repeating:0,count:CaptureProject.maximumBytes+1)) }
    var p = try project(); p.originalPNG = Data([137,80,78,71,13,10,26,10])
    #expect(throws:(any Error).self) { try p.image() }
    p.originalPNG = Data("not a PNG".utf8); #expect(!p.isValid)
}
@Test("TC-PRE-01/03/04 极光包边界及非法样式整体拒绝") func presetCompleteBounds() throws {
    var archive = PresetArchive(presets:[StylePreset(name:"我的极光",style:StylePreset.builtIns[8].style)])
    let normal = try archive.encoded()
    let imported = try PresetArchive.imported(normal,existing:[])
    #expect(imported.first?.style.background == .aurora)
    var boundary = normal; boundary.append(Data(repeating:32,count:PresetArchive.maximumBytes-normal.count))
    #expect(try PresetArchive.imported(boundary,existing:[]).count == 1)
    boundary.append(32); #expect(throws:(any Error).self) { try PresetArchive.imported(boundary,existing:[]) }
    var invalid = StylePreset.builtIns[0]; invalid.style.padding = -1; archive.presets.append(invalid)
    #expect(throws:(any Error).self) { try PresetArchive.imported(JSONEncoder().encode(archive),existing:[]) }
    archive.presets = Array(repeating:StylePreset.builtIns[0],count:101)
    #expect(throws:(any Error).self) { try PresetArchive.imported(JSONEncoder().encode(archive),existing:[]) }
}
@Test("TC-JOIN-03 拼图批量读取预检") func collageInputPreflight() throws {
    let dir = try temp(); defer { try? FileManager.default.removeItem(at:dir) }
    let a = dir.appendingPathComponent("a.png"), b = dir.appendingPathComponent("b.png")
    try StyleCompositor.encode(solid(width:100,height:80)).write(to:a); try StyleCompositor.encode(solid(width:90,height:70)).write(to:b)
    #expect(try CollageLayout.loadImages([a,b]).map(\.width) == [100,90])
    #expect(throws:(any Error).self) { try CollageLayout.loadImages(Array(repeating:a,count:13)) }
    #expect(throws:(any Error).self) { try CollageLayout.loadImages([a,dir.appendingPathComponent("missing")]) }
}
