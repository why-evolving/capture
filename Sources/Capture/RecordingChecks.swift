@preconcurrency import AVFoundation
import AppKit
import CaptureCore
import Carbon
@preconcurrency import CoreMedia
import ScreenCaptureKit
import SwiftUI

@MainActor enum RecordingChecks {
  static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw DeveloperChecks.CheckFailure(message) }
  }
  static func run(store: AppStore, directory: URL, screen: Bool) async throws {
    let root = directory.appendingPathComponent("sessions", isDirectory: true)
    var modes: [[String: Any]] = []
    var checks: [String] = []
    for mode in 0..<5 {
      var options = RecordingOptions()
      options.computerAudio = mode == 1 || mode == 3 || mode == 4
      options.microphone = mode == 2 || mode == 3
      options.countdown = 0
      if mode == 4 { options.computerVolume = 0 }
      let entry = try RecordingFiles.create(root: root, options: options)
      let writer = try RecordingWriter(
        url: entry.directory.appendingPathComponent("source.mov"),
        size: CGSize(width: 160, height: 96), options: options)
      for i in 0..<120 {
        if i == 30 { writer.pause(at: 101) }
        if i == 90 { writer.resume(at: 103) }
        let time = 100 + Double(i) / 30
        let video = try frame(time: time, color: i < 30 ? 0 : (i < 89 ? 1 : 2))
        let a = try tone(time: time, frequency: i >= 30 && i < 90 ? 2200 : 440)
        let b = try tone(time: time, frequency: i >= 30 && i < 90 ? 2200 : 880)
        await withCheckedContinuation { c in
          writer.queue.async {
            writer.append(video, source: .video)
            if options.computerAudio { writer.append(a, source: .computer) }
            if options.microphone { writer.append(b, source: .microphone) }
            c.resume()
          }
        }
        try await Task.sleep(for: .milliseconds(3))
      }
      let telemetry = try await writer.finish(at: 104)
      let completed = try await RecordingFiles.finish(entry)
      let info = try await RecordingFiles.inspect(completed.url)
      try require(info.audioTracks == (mode == 0 ? 0 : 1), "音源组合\(mode)没有输出预期的单混音轨")
      try require(abs(info.duration - 2) < 0.15, "暂停没有剔除或末尾丢失：\(info.duration)")
      let video = try await inspectVideo(completed.url)
      try require(video.red > 0 && video.blue > 0 && video.green == 0, "输出包含暂停画面或缺少动态帧")
      let audio = try await spectrum(completed.url)
      let expected440 = (mode == 1 || mode == 3)
      let expected880 = (mode == 2 || mode == 3)
      try require(
        (expected440 ? audio[0] > 0.03 : audio[0] < 0.015)
          && (expected880 ? audio[1] > 0.03 : audio[1] < 0.015) && audio[2] < 0.015,
        "混音频谱不符合开关/暂停/音量：\(mode), \(audio)")
      modes.append([
        "mode": mode, "computer": options.computerAudio, "microphone": options.microphone,
        "computerVolume": options.computerVolume, "duration": info.duration,
        "audioTracks": info.audioTracks, "amplitudes440_880_2200Hz": audio,
        "videoFrames": video.total, "pausedGreenFrames": video.green, "telemetry": telemetry,
        "sessionID": completed.id.uuidString,
      ])
    }
    checks += [
      "recording-four-audio-combinations", "recording-two-sources-single-aac-mix",
      "recording-zero-volume-silence", "recording-pause-video-and-audio-excluded",
      "recording-pause-duration-and-final-frame",
    ]
    try await permissions()
    checks += [
      "recording-mic-disabled-does-not-authorize",
      "recording-mic-denial-and-device-failure-preserve-choice",
    ]
    try hotkeys()
    checks += ["recording-independent-carbon-routing-and-suspension"]
    var brokenOptions = RecordingOptions()
    brokenOptions.computerAudio = false
    let broken = try RecordingFiles.create(root: root, options: brokenOptions)
    try Data("invalid source".utf8).write(to: broken.url)
    var failed = false
    do { _ = try await RecordingFiles.finish(broken) } catch { failed = true }
    try require(failed && FileManager.default.fileExists(atPath: broken.url.path), "失败导出没有保留原片")
    try require(
      (try RecordingFiles.entries(root: root)).contains(where: {
        $0.id == broken.id && !$0.completed
      }), "失败原片未进入恢复列表")
    try RecordingFiles.delete(broken, root: root)
    checks += ["recording-failed-export-retains-recoverable-source"]
    let entries = try RecordingFiles.entries(root: root)
    try require(entries.count == 5 && entries.allSatisfy { $0.completed }, "重启索引未恢复作品")
    let first = entries[0]
    let copy = directory.appendingPathComponent("saved-copy.mp4")
    try Data("original destination".utf8).write(to: copy)
    try RecordingFiles.copy(first.url, to: copy)
    try require(try Data(contentsOf: first.url) == Data(contentsOf: copy), "保存覆盖结果不一致")
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let controller = RecordingController(store: store, root: root)
    controller.copyResult(first, board: board)
    try require(
      (board.readObjects(forClasses: [NSURL.self]) as? [URL])?.first == first.url, "复制不是实际视频文件URL")
    let outside = directory.appendingPathComponent("external-original")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let link = root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let safe = try RecordingFiles.entries(root: root)
    try require(safe.count == 5, "索引跟随了软链接")
    var rejected = false
    do {
      try RecordingFiles.delete(
        RecordingEntry(
          id: UUID(), directory: outside, created: Date(), options: RecordingOptions(),
          completed: true), root: root)
    } catch { rejected = true }
    try require(rejected && FileManager.default.fileExists(atPath: outside.path), "删除越界目录未拒绝")
    try FileManager.default.removeItem(at: link)
    try RecordingFiles.delete(first, root: root)
    try require(
      FileManager.default.fileExists(atPath: copy.path)
        && (try RecordingFiles.entries(root: root)).count == 4, "删除会话破坏外部副本")
    checks += [
      "recording-atomic-save-and-private-file-clipboard",
      "recording-restart-index-and-delete-boundary", "recording-symlink-and-path-rejection",
    ]
    controller.showSetup()
    try await Task.sleep(for: .milliseconds(200))
    if let window = NSApp.windows.first(where: { $0.title == "录制屏幕" && $0.isVisible }) {
      try snapshot(window, name: "recording-setup", directory: directory)
      window.setContentSize(CGSize(width: 560, height: 620))
      try await Task.sleep(for: .milliseconds(100))
      try snapshot(window, name: "recording-setup-minimum", directory: directory)
    }
    controller.error = "麦克风未获授权。请允许Capture，或关闭麦克风后重试。"
    try await Task.sleep(for: .milliseconds(60))
    if let window = NSApp.windows.first(where: { $0.title == "录制屏幕" && $0.isVisible }) {
      try snapshot(window, name: "recording-error", directory: directory)
    }
    controller.error = nil
    await controller.showResult(entries[1])
    try await Task.sleep(for: .milliseconds(400))
    if let window = NSApp.windows.first(where: { $0.title == "录屏已完成" && $0.isVisible }) {
      try snapshot(window, name: "recording-result", directory: directory)
    }
    controller.saveResult(entries[1])
    try await Task.sleep(for: .milliseconds(150))
    try require(controller.fileBusy && controller.savePanel != nil, "录屏保存面板未进入忙碌状态")
    controller.savePanel?.cancel(nil)
    for _ in 0..<20 {
      if !controller.fileBusy { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    try require(
      !controller.fileBusy && FileManager.default.fileExists(atPath: entries[1].url.path),
      "取消保存丢失录屏或没有释放忙碌状态")
    checks += ["recording-native-save-panel-cancel-keeps-draft"]
    controller.shutdown()
    try selection(directory: directory)
    checks += [
      "recording-setup-result-error-minimum-layout",
      "recording-selection-hides-static-style-actions",
    ]
    var live: [String: Any] = ["result": "not_requested"]
    if screen {
      live = try await realCapture(store: store, directory: directory)
      checks += [
        "recording-real-own-window-live-stream", "recording-real-controller-pause-resume-save",
        "recording-real-area-display-4k60", "recording-capture-file-choice-exclusion",
      ]
    }
    let report: [String: Any] = [
      "result": "passed", "checks": checks, "audioModes": modes, "liveCapture": live,
      "screenCaptureAttempted": screen, "generalClipboardModified": false,
      "hardwareMicrophoneCaptured": false,
      "scope":
        "Generated video and PCM through production writer/exporter; native local controls/Carbon events; include-only app-owned live window when requested. No personal clipboard or ambient microphone capture.",
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
      .write(to: directory.appendingPathComponent("recording-checks.json"))
  }
  static func frame(time: Double, color: Int) throws -> CMSampleBuffer {
    var pixel: CVPixelBuffer?
    CVPixelBufferCreate(
      kCFAllocatorDefault, 160, 96, kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
    guard let pixel else { throw RecordingError.message("测试像素分配失败") }
    CVPixelBufferLockBaseAddress(pixel, [])
    let base = CVPixelBufferGetBaseAddress(pixel)!
    let stride = CVPixelBufferGetBytesPerRow(pixel)
    for y in 0..<96 {
      let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
      for x in 0..<160 {
        row[x * 4] = color == 2 ? 235 : 18
        row[x * 4 + 1] = color == 1 ? 235 : 18
        row[x * 4 + 2] = color == 0 ? 235 : 18
        row[x * 4 + 3] = 255
      }
    }
    CVPixelBufferUnlockBaseAddress(pixel, [])
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &format)
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 30),
      presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 48000),
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: format!,
      sampleTiming: &timing, sampleBufferOut: &sample)
    guard let sample else { throw RecordingError.message("测试帧创建失败") }
    return sample
  }
  static func tone(time: Double, frequency: Double) throws -> CMSampleBuffer {
    let count = 1600
    let sampleIndex = Int((time * 48000).rounded())
    let floats = (0..<count).map {
      Float(sin(2 * Double.pi * frequency * Double(sampleIndex + $0) / 48000) * 0.3)
    }
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count * 4,
      blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
      dataLength: count * 4, flags: 0, blockBufferOut: &block)
    guard let block else { throw RecordingError.message("测试音频分配失败") }
    _ = floats.withUnsafeBytes {
      CMBlockBufferReplaceDataBytes(
        with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count * 4)
    }
    var asbd = AudioStreamBasicDescription(
      mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
      mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32,
      mReserved: 0)
    var format: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
      magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 48000),
      presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 48000),
      decodeTimeStamp: .invalid)
    var size = 4
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format!,
      sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
      sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
    guard let sample else { throw RecordingError.message("测试音频创建失败") }
    return sample
  }
  static func inspectVideo(_ url: URL) async throws -> (red: Int, green: Int, blue: Int, total: Int)
  {
    let asset = AVURLAsset(url: url)
    let reader = try AVAssetReader(asset: asset)
    let track = try await asset.loadTracks(withMediaType: .video).first!
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    try require(reader.startReading(), "视频解码启动失败")
    var colors = [0, 0, 0]
    var total = 0
    while let sample = output.copyNextSampleBuffer() {
      guard let pixel = CMSampleBufferGetImageBuffer(sample) else { continue }
      CVPixelBufferLockBaseAddress(pixel, .readOnly)
      let x = CVPixelBufferGetWidth(pixel) / 2
      let y = CVPixelBufferGetHeight(pixel) / 2
      let data = CVPixelBufferGetBaseAddress(pixel)!.advanced(
        by: y * CVPixelBufferGetBytesPerRow(pixel) + x * 4
      ).assumingMemoryBound(to: UInt8.self)
      let b = Int(data[0])
      let g = Int(data[1])
      let r = Int(data[2])
      if r > g + 80 && r > b + 80 { colors[0] += 1 }
      if g > r + 80 && g > b + 80 { colors[1] += 1 }
      if b > r + 80 && b > g + 80 { colors[2] += 1 }
      CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
      total += 1
      try require(total < 10000, "视频帧数超限")
    }
    return (colors[0], colors[1], colors[2], total)
  }
  static func spectrum(_ url: URL) async throws -> [Double] {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
      return [0, 0, 0]
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
      ])
    reader.add(output)
    try require(reader.startReading(), "音频解码启动失败")
    var values: [Float] = []
    while let sample = output.copyNextSampleBuffer() {
      guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
      let length = CMBlockBufferGetDataLength(block)
      var chunk = [Float](repeating: 0, count: length / 4)
      _ = chunk.withUnsafeMutableBytes {
        CMBlockBufferCopyDataBytes(
          block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
      }
      values += chunk
      try require(values.count < 1_000_000, "音频夹具超出范围")
    }
    // Average short-window magnitudes: a real pause joins unrelated tone phases,
    // so a single whole-clip correlation can incorrectly cancel a valid source.
    return [440.0, 880, 2200].map { frequency in
      var weightedMagnitude = 0.0
      for start in stride(from: 0, to: values.count, by: 4800) {
        let end = min(values.count, start + 4800)
        var a = 0.0
        var b = 0.0
        for i in start..<end {
          let phase = 2 * Double.pi * frequency * Double(i - start) / 48000
          a += Double(values[i]) * sin(phase)
          b += Double(values[i]) * cos(phase)
        }
        weightedMagnitude += 2 * hypot(a, b)
      }
      return weightedMagnitude / Double(max(1, values.count))
    }
  }

  static func permissions() async throws {
    var calls = 0
    var requests = 0
    var devices = 0
    var options = RecordingOptions()
    var access = RecordingAudioAccess(
      status: {
        calls += 1
        return .denied
      },
      request: {
        requests += 1
        return false
      }, validateDevice: { _ in devices += 1 })
    try await access.prepare(options)
    try require(calls == 0 && requests == 0 && devices == 0, "麦克风关闭时仍访问设备/授权")
    options.microphone = true
    var failed = false
    do { try await access.prepare(options) } catch { failed = true }
    try require(failed && requests == 0 && devices == 0 && options.microphone, "拒绝权限时静默丢音源或继续连接")
    access.status = { .notDetermined }
    failed = false
    do { try await access.prepare(options) } catch { failed = true }
    try require(failed && requests == 1 && devices == 0, "首次权限拒绝没有阻止开始")
    access.status = { .authorized }
    access.validateDevice = { _ in throw RecordingError.message("设备丢失") }
    failed = false
    do { try await access.prepare(options) } catch { failed = true }
    try require(failed, "设备丢失没有阻止开始")
    access.validateDevice = { _ in devices += 1 }
    try await access.prepare(options)
    try require(devices == 1 && requests == 1, "已有授权不应再次请求")
  }
  static func hotkeys() throws {
    let a = GlobalHotKey()
    let b = GlobalHotKey()
    defer {
      a.dispose()
      b.dispose()
    }
    let mask: UInt32 = (1 << 8) | (1 << 9) | (1 << 11) | (1 << 12)
    try a.register(Shortcut(keyCode: 64, modifiers: mask, keyLabel: "F17"))
    try b.register(Shortcut(keyCode: 106, modifiers: mask, keyLabel: "F16"))
    var counts = [0, 0]
    a.onCapture = { counts[0] += 1 }
    b.onCapture = { counts[1] += 1 }
    func send(_ id: UInt32) throws {
      var event: EventRef?
      CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event)
      guard let event else { throw RecordingError.message("热键事件创建失败") }
      defer { ReleaseEvent(event) }
      var key = EventHotKeyID(signature: 0x4350_5452, id: id)
      SetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        MemoryLayout<EventHotKeyID>.size, &key)
      try require(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr, "热键事件没有被处理")
    }
    try send(a.identifier)
    try require(counts == [1, 0], "截图事件误触发录屏")
    try send(b.identifier)
    try require(counts == [1, 1], "录屏事件误触发截图")
    a.suspend()
    b.suspend()
    try send(a.identifier)
    try send(b.identifier)
    try require(counts == [1, 1], "录入期间仍触发热键")
    try a.resume()
    try b.resume()
    try send(b.identifier)
    try require(counts == [1, 2] && a.isRegistered && b.isRegistered, "两组热键未恢复")
  }
  static func selection(directory: URL) throws {
    let window = SelectionPanel(
      contentRect: CGRect(x: 0, y: 0, width: 900, height: 620),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = SelectionView(frame: window.contentLayoutRect)
    view.adjustable = true
    view.recordingSelection = true
    view.configureStyles(presets: [], appearance: nil, confirmTitle: "确认范围")
    window.contentView = view
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
      NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 100, y: 450)))
    view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 600, y: 180)))
    view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 600, y: 180)))
    try require(
      view.ready && view.toolbar.styles.isHidden && view.toolbar.customize.isHidden
        && !view.toolbar.recordingNote.isHidden, "录屏选区仍显示截图样式或未就绪")
    try snapshot(window, name: "recording-selection", directory: directory)
  }
  static func captureVariants(own: SCWindow, window: NSWindow, directory: URL) async throws
    -> [[String: Any]]
  {
    var result: [[String: Any]] = []
    let root = directory.appendingPathComponent("variant-sessions")
    // Crop a known self-owned window. The full-display case uses an include-only black backdrop.
    let crop = CGRect(x: 80, y: 45, width: 320, height: 180)
    var options = RecordingOptions()
    options.computerAudio = false
    options.framesPerSecond = 60
    options.quality = .high
    options.countdown = 0
    let filter = SCContentFilter(desktopIndependentWindow: own)
    let cropSize = options.outputSize(
      source: CGSize(
        width: crop.width * Double(filter.pointPixelScale),
        height: crop.height * Double(filter.pointPixelScale)))!
    let entry = try RecordingFiles.create(root: root, options: options)
    let engine = RecordingEngine()
    try await engine.start(
      filter: filter, size: cropSize, sourceRect: crop, options: options, entry: entry)
    try await Task.sleep(for: .milliseconds(450))
    _ = try await engine.stop()
    let cropped = try await RecordingFiles.finish(entry)
    let cropInfo = try await RecordingFiles.inspect(cropped.url)
    let colors = try await inspectVideo(cropped.url)
    try require(
      cropInfo.size == cropSize && colors.blue > 0 && colors.red == 0 && colors.green == 0,
      "区域录屏裁剪/尺寸不正确")
    result.append([
      "scope": "area", "fpsConfigured": 60,
      "pixels": [Int(cropInfo.size.width), Int(cropInfo.size.height)],
      "file": "variant-sessions/" + cropped.id.uuidString + "/recording.mp4",
    ])
    guard let screen = window.screen,
      let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
        .uint32Value
    else { throw RecordingError.message("没有找到自有测试屏幕") }
    let backdrop = NSWindow(
      contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    backdrop.isReleasedWhenClosed = false
    backdrop.backgroundColor = .black
    backdrop.orderBack(nil)
    defer { backdrop.close() }
    try await Task.sleep(for: .milliseconds(200))
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == id }),
      let background = content.windows.first(where: {
        $0.windowID == CGWindowID(backdrop.windowNumber)
      })
    else { throw RecordingError.message("找不到自有测试背景") }
    let fullFilter = SCContentFilter(display: display, including: [background, own])
    let size = options.outputSize(
      source: CGSize(
        width: fullFilter.contentRect.width * Double(fullFilter.pointPixelScale),
        height: fullFilter.contentRect.height * Double(fullFilter.pointPixelScale)))!
    let fullEntry = try RecordingFiles.create(root: root, options: options)
    let fullEngine = RecordingEngine()
    try await fullEngine.start(filter: fullFilter, size: size, options: options, entry: fullEntry)
    try await Task.sleep(for: .milliseconds(450))
    _ = try await fullEngine.stop()
    let finished = try await RecordingFiles.finish(fullEntry)
    let info = try await RecordingFiles.inspect(finished.url)
    try require(info.size == size && info.size.width > 1920, "全屏4K录屏尺寸或解码失败")
    result.append([
      "scope": "display-own-windows-only", "fpsConfigured": 60,
      "pixels": [Int(info.size.width), Int(info.size.height)],
      "file": "variant-sessions/" + finished.id.uuidString + "/recording.mp4",
    ])
    return result
  }
  static func wav() -> Data {
    let samples = (0..<48000).map { Int16(sin(2 * Double.pi * 440 * Double($0) / 48000) * 8000) }
    var data = Data()
    func text(_ s: String) { data.append(contentsOf: s.utf8) }
    func u16(_ n: UInt16) {
      var n = n.littleEndian
      withUnsafeBytes(of: &n) { data.append(contentsOf: $0) }
    }
    func u32(_ n: UInt32) {
      var n = n.littleEndian
      withUnsafeBytes(of: &n) { data.append(contentsOf: $0) }
    }
    text("RIFF")
    u32(UInt32(36 + samples.count * 2))
    text("WAVEfmt ")
    u32(16)
    u16(1)
    u16(1)
    u32(48000)
    u32(96000)
    u16(2)
    u16(16)
    text("data")
    u32(UInt32(samples.count * 2))
    samples.forEach { u16(UInt16(bitPattern: $0)) }
    return data
  }
  static func snapshot(_ window: NSWindow, name: String, directory: URL) throws {
    guard let view = window.contentView else { throw RecordingError.message("没有测试视图") }
    view.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw RecordingError.message("界面快照失败")
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    if let cg = bitmap.cgImage {
      try StyleCompositor.encode(cg).write(to: directory.appendingPathComponent(name + ".png"))
    }
  }
  static func realCapture(store: AppStore, directory: URL) async throws -> [String: Any] {
    guard CGPreflightScreenCaptureAccess(),
      (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool
        != true
    else { throw DeveloperChecks.CheckBlocked("录屏真实自有窗口测试需要解锁及屏幕录制权限。") }
    let sample = RecordingDynamicSample(frame: CGRect(x: 0, y: 0, width: 480, height: 270))
    let window = NSWindow(
      contentRect: CGRect(x: 240, y: 200, width: 480, height: 270), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.backgroundColor = .systemRed
    sample.wantsLayer = true
    sample.layer?.backgroundColor = NSColor.systemRed.cgColor
    window.contentView = sample
    window.level = .floating
    window.orderFrontRegardless()
    defer { window.close() }
    var own: SCWindow?
    for _ in 0..<20 {
      try await Task.sleep(for: .milliseconds(100))
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)
      own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) })
      if own != nil { break }
    }
    guard let own else { throw DeveloperChecks.CheckFailure("没有找到录屏自有样例窗口（未使用其他窗口代替）") }
    let filter = SCContentFilter(desktopIndependentWindow: own)
    let root = directory.appendingPathComponent("live-sessions")
    let board = NSPasteboard.withUniqueName()
    let app = AppController(
      store: store, clipboard: board,
      libraryDirectory: directory.appendingPathComponent("live-library"), recordingDirectory: root)
    let c = app.recording
    defer {
      app.stop()
      board.releaseGlobally()
    }
    c.options.scope = .display
    c.options.computerAudio = true
    c.options.microphone = false
    c.options.countdown = 0
    c.capturePlan = { _, _ in
      RecordingController.CapturePlan(
        filter: filter,
        sourceSize: CGSize(
          width: 480 * Double(filter.pointPixelScale), height: 270 * Double(filter.pointPixelScale)),
        sourceRect: nil, excludeOwnAudio: false)
    }
    let toneURL = directory.appendingPathComponent("own-tone.wav")
    try wav().write(to: toneURL)
    guard let sound = NSSound(contentsOf: toneURL, byReference: false) else {
      throw DeveloperChecks.CheckFailure("无法创建自有测试音")
    }
    sound.volume = 0.25
    sound.loops = true
    defer { sound.stop() }
    c.start()
    for _ in 0..<100 {
      if c.phase == .recording { break }
      if c.error != nil { throw DeveloperChecks.CheckFailure(c.error!) }
      try await Task.sleep(for: .milliseconds(80))
    }
    try require(c.phase == .recording, "真实录屏未启动")
    try require(!app.canStartCapture && !app.beginFileChoice(NSOpenPanel()), "录屏期间仍允许截图/文件面板")
    sound.play()
    try await Task.sleep(for: .milliseconds(650))
    try snapshot(
      NSApp.windows.first(where: { $0.contentView is NSHostingView<RecordingHUD> })!,
      name: "recording-hud", directory: directory)
    let pausedHost = CMClockGetTime(CMClockGetHostTimeClock()).seconds
    c.togglePause()
    sample.color = 1
    window.backgroundColor = .systemGreen
    sample.layer?.backgroundColor = NSColor.systemGreen.cgColor
    sample.needsDisplay = true
    window.displayIfNeeded()
    CATransaction.flush()
    try await Task.sleep(for: .milliseconds(300))
    if let hud = NSApp.windows.first(where: { $0.contentView is NSHostingView<RecordingHUD> }) {
      try snapshot(hud, name: "recording-paused", directory: directory)
    }
    sample.color = 2
    window.backgroundColor = .systemBlue
    sample.layer?.backgroundColor = NSColor.systemBlue.cgColor
    sample.needsDisplay = true
    window.displayIfNeeded()
    CATransaction.flush()
    try await Task.sleep(for: .milliseconds(250))
    let blueSource = try await ScreenCaptureService.freeze(
      filter: filter, size: CGSize(width: 480, height: 270), scale: Double(filter.pointPixelScale))
    try StyleCompositor.encode(blueSource.image).write(
      to: directory.appendingPathComponent("live-source-blue.png"))
    let resumedHost = CMClockGetTime(CMClockGetHostTimeClock()).seconds
    c.togglePause()
    try await Task.sleep(for: .milliseconds(650))
    let stoppedHost = CMClockGetTime(CMClockGetHostTimeClock()).seconds
    await c.finish()
    guard let result = c.result else { throw DeveloperChecks.CheckFailure(c.error ?? "真实录屏没有完成作品") }
    let info = try await RecordingFiles.inspect(result.url)
    let video = try await inspectVideo(result.url)
    let audio = try await spectrum(result.url)
    try JSONSerialization.data(
      withJSONObject: [
        "red": video.red, "green": video.green, "blue": video.blue, "total": video.total,
        "audio": audio, "duration": info.duration,
      ], options: .prettyPrinted
    ).write(to: directory.appendingPathComponent("live-diagnostics.json"))
    try require(
      info.audioTracks == 1 && audio[0] > 0.008 && audio[1] < 0.015,
      "真实电脑声音没有捕获应用自有440Hz测试音：\(audio)")
    try require(video.red > 0 && video.blue > 0 && video.green == 0, "真实录屏未更新或录入暂停画面")
    let telemetry =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: result.directory.appendingPathComponent("recording-info.json")))
      as! [String: Any]
    guard let origin = telemetry["sourceStartHostSeconds"] as? Double else {
      throw DeveloperChecks.CheckFailure("没有记录真实源帧时钟")
    }
    let expectedDuration = stoppedHost - origin - (resumedHost - pausedHost)
    try require(
      info.duration > 1 && abs(info.duration - expectedDuration) < 0.15,
      "真实录屏时间线与独立时钟不符：actual=\(info.duration), expected=\(expectedDuration)")
    let variants = try await captureVariants(own: own, window: window, directory: directory)
    return [
      "variants": variants,
      "result": "passed",
      "scope":
        "Include-only own generated dynamic window and this app own tone; no microphone or third-party windows/audio",
      "computerAudio440HzAmplitude": audio[0], "duration": info.duration,
      "independentHostExpectedSeconds": expectedDuration,
      "pixels": [Int(info.size.width), Int(info.size.height)], "decodedFrames": video.total,
      "redFrames": video.red, "blueFrames": video.blue, "pausedGreenFrames": video.green,
      "file": "live-sessions/" + result.id.uuidString + "/recording.mp4",
    ]
  }
}
private final class RecordingDynamicSample: NSView {
  var color = 0
}
