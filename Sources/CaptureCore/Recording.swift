import Foundation

public enum RecordingScope: String, Codable, CaseIterable, Sendable {
  case area, window, display
  public var label: String {
    switch self {
    case .area: "区域"
    case .window: "窗口"
    case .display: "全屏"
    }
  }
  public var symbol: String {
    switch self {
    case .area: "viewfinder"
    case .window: "macwindow"
    case .display: "display"
    }
  }
}
public enum RecordingQuality: String, Codable, CaseIterable, Sendable {
  case standard, high
  public var label: String { self == .standard ? "1080p · 清晰省空间" : "4K · 更多细节" }
  public var maximumSize: CGSize {
    self == .standard ? CGSize(width: 1920, height: 1080) : CGSize(width: 3840, height: 2160)
  }
}
public struct RecordingOptions: Codable, Equatable, Sendable {
  public var scope: RecordingScope = .area
  public var quality: RecordingQuality = .standard
  public var framesPerSecond = 30
  public var computerAudio = true
  public var microphone = false
  public var microphoneID: String? = nil
  public var computerVolume: Double = 1
  public var microphoneVolume: Double = 1
  public var includeCursor = true
  public var countdown = 3
  public var shortcut = Shortcut.defaultRecording
  public var adjustBeforeRecording: Bool? = nil
  public var allowsRecordingAdjustment: Bool { adjustBeforeRecording ?? false }
  public init() {}
  public static func defaults(captureShortcut: Shortcut) -> RecordingOptions {
    var value = RecordingOptions()
    if value.shortcut.hasSameKeys(as: captureShortcut) { value.shortcut.modifiers |= (1 << 11) }
    return value
  }
  public var isValid: Bool {
    [30, 60].contains(framesPerSecond) && [0, 3, 5].contains(countdown) && shortcut.isValid
      && computerVolume.isFinite && (0...1).contains(computerVolume) && microphoneVolume.isFinite
      && (0...1).contains(microphoneVolume)
      && (microphoneID == nil || (!microphoneID!.isEmpty && microphoneID!.count <= 512))
  }
  public func outputSize(source: CGSize) -> CGSize? {
    guard isValid, source.width.isFinite, source.height.isFinite, source.width >= 16,
      source.height >= 16, source.width <= 32000, source.height <= 32000
    else { return nil }
    let limit = quality.maximumSize
    let factor = min(
      1,
      min(
        max(limit.width, limit.height) / max(source.width, source.height),
        min(limit.width, limit.height) / min(source.width, source.height)))
    return CGSize(
      width: max(2, floor(source.width * factor / 2) * 2),
      height: max(2, floor(source.height * factor / 2) * 2))
  }
  public var audioLabel: String {
    [computerAudio ? "电脑声音" : nil, microphone ? "麦克风" : nil].compactMap { $0 }.joined(
      separator: " + "
    ).nilIfEmpty ?? "静音"
  }
}
extension String { fileprivate var nilIfEmpty: String? { isEmpty ? nil : self } }
extension Shortcut {
  public static let defaultRecording = Shortcut(
    keyCode: 26, modifiers: (1 << 8) | (1 << 9), keyLabel: "7")
  public func hasSameKeys(as other: Shortcut) -> Bool {
    keyCode == other.keyCode && modifiers == other.modifiers
  }
}
/// All inputs use the capture host clock. Media timestamps, not wall-clock dates, determine output.
public struct RecordingTimeline: Sendable {
  public private(set) var origin: Double?
  public private(set) var pausedAt: Double?
  public private(set) var pausedDuration = 0.0
  private var resumeBoundary: Double?
  public init() {}
  public mutating func begin(at time: Double) { if time.isFinite, origin == nil { origin = time } }
  public mutating func pause(at time: Double) {
    if time.isFinite, pausedAt == nil { pausedAt = time }
  }
  public mutating func resume(at time: Double) {
    guard time.isFinite, let start = pausedAt, time >= start else { return }
    // A pause before the first frame must not create a negative starting offset.
    if let origin { pausedDuration += max(0, time - max(start, origin)) }
    pausedAt = nil
    resumeBoundary = time
  }
  public func mapped(_ time: Double) -> Double? {
    guard time.isFinite, pausedAt == nil, let origin, time >= origin,
      time + 0.000001 >= (resumeBoundary ?? origin)
    else { return nil }
    return max(0, time - origin - pausedDuration)
  }
}
public enum RecordingLimits {
  public static let startFreeBytes: Int64 = 512 * 1024 * 1024
  public static let stopFreeBytes: Int64 = 128 * 1024 * 1024
  public static let maximumSeconds = 3600.0
  public static func stopReason(seconds: Double, freeBytes: Int64) -> String? {
    if freeBytes < stopFreeBytes { return "磁盘空间不足，已停止并保存当前录屏。" }
    if seconds >= maximumSeconds { return "已达到60分钟录制上限，已停止并保存。" }
    return nil
  }
}
