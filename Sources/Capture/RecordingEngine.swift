import AVFoundation
import AppKit
import CaptureCore
import ScreenCaptureKit

@MainActor
final class RecordingEngine: NSObject, SCStreamDelegate {
  private var stream: SCStream?
  private var micSession: AVCaptureSession?
  private(set) var writer: RecordingWriter?
  private var stopping = false
  var onError: ((String) -> Void)?
  func start(
    filter: SCContentFilter, size: CGSize, sourceRect: CGRect? = nil, options: RecordingOptions,
    entry: RecordingEntry, excludeOwnAudio: Bool = true,
    onProgress: @escaping (Double) -> Void = { _ in }
  ) async throws {
    guard stream == nil else { throw RecordingError.message("已有录屏正在进行。") }
    let config = SCStreamConfiguration()
    config.width = Int(size.width)
    config.height = Int(size.height)
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.framesPerSecond))
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.queueDepth = 5
    config.showsCursor = options.includeCursor
    config.capturesAudio = options.computerAudio
    config.excludesCurrentProcessAudio = excludeOwnAudio
    config.sampleRate = 48000
    config.channelCount = 2
    config.colorSpaceName = CGColorSpace.sRGB
    if let sourceRect { config.sourceRect = sourceRect }
    if #available(macOS 15.0, *) {
      config.captureMicrophone = options.microphone
      config.microphoneCaptureDeviceID = options.microphoneID
    }
    let sink = try RecordingWriter(
      url: entry.directory.appendingPathComponent("source.mov"), size: size, options: options)
    sink.onProgress = onProgress
    sink.onFailure = { [weak self] error in
      Task { @MainActor in self?.onError?(error.localizedDescription) }
    }
    writer = sink
    let stream = SCStream(filter: filter, configuration: config, delegate: self)
    self.stream = stream
    do {
      try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
      if options.computerAudio {
        try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
      }
      if options.microphone {
        if #available(macOS 15.0, *) {
          try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sink.queue)
        } else {
          let device = try Self.microphone(id: options.microphoneID)
          micSession = try await Task.detached {
            let session = AVCaptureSession()
            session.beginConfiguration()
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureAudioDataOutput()
            guard session.canAddInput(input), session.canAddOutput(output) else {
              throw RecordingError.message("无法连接麦克风。")
            }
            session.addInput(input)
            session.addOutput(output)
            output.setSampleBufferDelegate(sink, queue: sink.queue)
            session.commitConfiguration()
            session.startRunning()
            return session
          }.value
        }
      }
      try await stream.startCapture()
    } catch {
      await cancel()
      throw error
    }
  }
  static func devices() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(
      deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
    ).devices
  }
  static func microphone(id: String?) throws -> AVCaptureDevice {
    if let id {
      guard let device = devices().first(where: { $0.uniqueID == id }) else {
        throw RecordingError.message("所选麦克风已断开，请刷新设备或重新选择。")
      }
      return device
    }
    guard let device = AVCaptureDevice.default(for: .audio) else {
      throw RecordingError.message("未找到可用麦克风。")
    }
    return device
  }
  func stop() async throws -> [String: Any] {
    guard !stopping, let writer else { throw RecordingError.message("没有可停止的录屏。") }
    stopping = true
    let end = CMClockGetTime(CMClockGetHostTimeClock()).seconds
    try? await stream?.stopCapture()
    stream = nil
    if let micSession { await Task.detached { micSession.stopRunning() }.value }
    micSession = nil
    defer { self.writer = nil }
    return try await writer.finish(at: end)
  }
  func cancel() async {
    stopping = true
    try? await stream?.stopCapture()
    stream = nil
    if let micSession { await Task.detached { micSession.stopRunning() }.value }
    micSession = nil
    writer?.cancel()
    writer = nil
  }
  nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
    Task { @MainActor [weak self] in
      guard let self, !self.stopping else { return }
      self.onError?(error.localizedDescription)
    }
  }
}
