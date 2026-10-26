import AVFoundation
import CaptureCore
import Foundation

struct RecordingEntry: Identifiable, Equatable, Sendable {
  let id: UUID
  let directory: URL
  let created: Date
  let options: RecordingOptions
  var completed: Bool
  var url: URL { directory.appendingPathComponent(completed ? "recording.mp4" : "source.mov") }
  var title: String { created.formatted(date: .abbreviated, time: .shortened) }
}
enum RecordingFiles {
  struct Metadata: Codable {
    var version = 1
    let id: UUID
    let created: Date
    let options: RecordingOptions
  }
  static var defaultRoot: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Capture/Recordings", isDirectory: true)
  }
  static func create(root: URL, options: RecordingOptions) throws -> RecordingEntry {
    guard options.isValid else { throw RecordingError.message("录屏选项无效。") }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try rejectLink(root)
    guard
      try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count
        < 500
    else { throw RecordingError.message("本地录屏达到500个，请先在最近录屏中清理不需要的作品。") }
    let id = UUID()
    let date = Date()
    let dir = root.appendingPathComponent(id.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(Metadata(id: id, created: date, options: options)).write(
      to: dir.appendingPathComponent("session.json"), options: .atomic)
    return RecordingEntry(id: id, directory: dir, created: date, options: options, completed: false)
  }
  static func rejectLink(_ url: URL) throws {
    guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
      throw RecordingError.message("录屏目录或文件不能是符号链接。")
    }
  }
  static func entries(root: URL) throws -> [RecordingEntry] {
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    try rejectLink(root)
    let children = try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: .skipsHiddenFiles)
    guard children.count <= 500 else { throw RecordingError.message("录屏目录数量超限，请在Finder中检查。") }
    var result: [RecordingEntry] = []
    for dir in children {
      guard let id = UUID(uuidString: dir.lastPathComponent),
        (try? dir.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])).map({
          $0.isSymbolicLink != true && $0.isDirectory == true
        }) == true
      else { continue }
      let meta = dir.appendingPathComponent("session.json")
      guard (try? rejectLink(meta)) != nil,
        let size = try? meta.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65536,
        let data = try? Data(contentsOf: meta),
        let m = try? JSONDecoder().decode(Metadata.self, from: data), m.version == 1, m.id == id,
        m.options.isValid, m.created.timeIntervalSince1970.isFinite,
        m.created.timeIntervalSince1970 > 0, m.created < Date().addingTimeInterval(86400)
      else { continue }
      let final = dir.appendingPathComponent("recording.mp4")
      let source = dir.appendingPathComponent("source.mov")
      let completed = FileManager.default.fileExists(atPath: final.path)
      let file = completed ? final : source
      guard (try? rejectLink(file)) != nil,
        (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
      else { continue }
      result.append(
        RecordingEntry(
          id: id, directory: dir, created: m.created, options: m.options, completed: completed))
    }
    return result.sorted { $0.created > $1.created }
  }
  static func delete(_ entry: RecordingEntry, root: URL) throws {
    try rejectLink(root)
    try rejectLink(entry.directory)
    guard
      entry.directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
      entry.directory.lastPathComponent == entry.id.uuidString
    else { throw RecordingError.message("拒绝删除录屏目录以外的文件。") }
    try FileManager.default.removeItem(at: entry.directory)
  }
  static func freeBytes(at url: URL) -> Int64 {
    ((try? FileManager.default.attributesOfFileSystem(forPath: url.path)[.systemFreeSize])
      as? NSNumber)?.int64Value ?? 0
  }
  static func finish(_ entry: RecordingEntry) async throws -> RecordingEntry {
    let source = entry.directory.appendingPathComponent("source.mov")
    let target = entry.directory.appendingPathComponent("recording.mp4")
    try rejectLink(entry.directory)
    try rejectLink(source)
    let asset = AVURLAsset(url: source)
    let composition = AVMutableComposition()
    let duration = try await asset.load(.duration)
    guard duration.seconds.isFinite, duration.seconds > 0,
      duration.seconds <= RecordingLimits.maximumSeconds + 30,
      let video = try await asset.loadTracks(withMediaType: .video).first,
      let output = composition.addMutableTrack(
        withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
    else { throw RecordingError.message("原片没有有效视频，已保留供检查。") }
    let range = CMTimeRange(start: .zero, duration: duration)
    try output.insertTimeRange(range, of: video, at: .zero)
    let audios = try await asset.loadTracks(withMediaType: .audio)
    guard audios.count <= 2 else { throw RecordingError.message("原片音轨数量异常。") }
    var params: [AVAudioMixInputParameters] = []
    for track in audios {
      guard
        let dest = composition.addMutableTrack(
          withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
      else { throw RecordingError.message("无法创建混音轨道。") }
      let available = try await track.load(.timeRange)
      let intersection = CMTimeRangeGetIntersection(range, otherRange: available)
      if intersection.duration > CMTime.zero {
        try dest.insertTimeRange(intersection, of: track, at: intersection.start)
      }
      let p = AVMutableAudioMixInputParameters(track: dest)
      // Writer input order is computer first, microphone second. No enabled track is omitted.
      let metadata = try await track.load(.metadata)
      var source: String?
      for item in metadata where item.commonKey == .commonKeyTitle {
        source = try await item.load(.stringValue)
      }
      guard source == "capture.computer" || source == "capture.microphone" else {
        throw RecordingError.message("原片音源标记缺失，未猜测混音音量。")
      }
      let gain =
        source == "capture.computer" ? entry.options.computerVolume : entry.options.microphoneVolume
      p.setVolume(Float(gain * (audios.count == 2 ? 0.35 : 1)), at: .zero)
      params.append(p)
    }
    guard
      let exporter = AVAssetExportSession(
        asset: composition, presetName: AVAssetExportPresetHighestQuality)
    else { throw RecordingError.message("无法创建MP4编码器。") }
    let temp = entry.directory.appendingPathComponent("export-" + UUID().uuidString + ".mp4")
    defer { try? FileManager.default.removeItem(at: temp) }
    let mix = AVMutableAudioMix()
    mix.inputParameters = params
    exporter.audioMix = mix
    exporter.outputFileType = .mp4
    exporter.outputURL = temp
    exporter.shouldOptimizeForNetworkUse = true
    await exporter.export()
    guard exporter.status == .completed else {
      throw exporter.error ?? RecordingError.message("MP4导出未完成，原片已保留，可重试。")
    }
    _ = try await inspect(temp)
    guard !Task.isCancelled else { throw CancellationError() }
    if FileManager.default.fileExists(atPath: target.path) {
      throw RecordingError.message("已存在完成文件，请重新打开最近录屏。")
    }
    try FileManager.default.moveItem(at: temp, to: target)
    try? FileManager.default.removeItem(at: source)
    var result = entry
    result.completed = true
    return result
  }
  static func inspect(_ url: URL) async throws -> (
    duration: Double, size: CGSize, bytes: Int64, audioTracks: Int
  ) {
    try rejectLink(url)
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    guard duration.seconds.isFinite, duration.seconds > 0,
      let track = try await asset.loadTracks(withMediaType: .video).first
    else { throw RecordingError.message("视频文件无效。") }
    let size = try await track.load(.naturalSize)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    guard reader.startReading(), output.copyNextSampleBuffer() != nil else {
      throw reader.error ?? RecordingError.message("视频无法解码。")
    }
    reader.cancelReading()
    return (
      duration.seconds, size, Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0),
      try await asset.loadTracks(withMediaType: .audio).count
    )
  }
  static func copy(_ source: URL, to target: URL) throws {
    try rejectLink(source)
    guard source.standardizedFileURL != target.standardizedFileURL else { return }
    if FileManager.default.fileExists(atPath: target.path) {
      try rejectLink(target)
      guard try target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true else {
        throw RecordingError.message("保存目标是文件夹，未覆盖。")
      }
    }
    let temp = target.deletingLastPathComponent().appendingPathComponent(
      ".capture-" + UUID().uuidString + ".mp4")
    defer { try? FileManager.default.removeItem(at: temp) }
    try FileManager.default.copyItem(at: source, to: temp)
    if FileManager.default.fileExists(atPath: target.path) {
      _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
    } else {
      try FileManager.default.moveItem(at: temp, to: target)
    }
  }
}
