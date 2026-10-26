import AVFoundation
import AppKit
import CaptureCore
import ScreenCaptureKit

/// Its serial queue exclusively owns all writer state and timestamp mapping.
final class RecordingWriter: NSObject, SCStreamOutput, AVCaptureAudioDataOutputSampleBufferDelegate,
  @unchecked Sendable
{
  enum Source: Hashable { case video, computer, microphone }
  let queue = DispatchQueue(label: "Capture.recording.writer", qos: .userInitiated)
  private let writer: AVAssetWriter
  private let video: AVAssetWriterInput
  private let computer: AVAssetWriterInput?
  private let microphone: AVAssetWriterInput?
  private var timeline = RecordingTimeline()
  private var lastTimes: [Source: Double] = [:]
  private var lastVideo: CMSampleBuffer?
  private var latestObservedVideo: CMSampleBuffer?
  private var accepting = true
  private var failure: Error?
  private var frameCount = 0
  private var statuses: [Int: Int] = [:]
  private var audioCounts = [0, 0]
  private var dropped = 0
  private let fps: Int
  var onFailure: ((Error) -> Void)?
  var onProgress: ((Double) -> Void)?
  init(url: URL, size: CGSize, options: RecordingOptions) throws {
    fps = options.framesPerSecond
    writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
    video = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width),
        AVVideoHeightKey: Int(size.height),
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: Int(size.width * size.height * Double(fps) * 0.12),
          AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalKey: fps * 2,
        ],
      ])
    video.expectsMediaDataInRealTime = true
    func audio(_ channels: Int) -> AVAssetWriterInput {
      let i = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
          AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 128000,
        ])
      i.expectsMediaDataInRealTime = true
      return i
    }
    computer = options.computerAudio ? audio(2) : nil
    microphone = options.microphone ? audio(1) : nil
    for (input, title) in [(computer, "capture.computer"), (microphone, "capture.microphone")] {
      let item = AVMutableMetadataItem()
      item.identifier = .commonIdentifierTitle
      item.value = title as NSString
      input?.metadata = [item]
    }
    super.init()
    for input in [video, computer, microphone].compactMap({ $0 }) {
      guard writer.canAdd(input) else { throw RecordingError.message("当前编码器不支持所选音视频配置。") }
      writer.add(input)
    }
    guard writer.startWriting() else { throw writer.error ?? RecordingError.message("无法创建录制文件。") }
    writer.startSession(atSourceTime: .zero)
  }
  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    if type == .screen {
      if let a = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        as? [[SCStreamFrameInfo: Any]], let status = a.first?[.status] as? Int
      {
        statuses[status, default: 0] += 1
      }
      guard
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
          sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
        let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue
      else { return }
      append(sampleBuffer, source: .video)
    } else if type == .audio {
      append(sampleBuffer, source: .computer)
    } else if #available(macOS 15.0, *), type == .microphone {
      append(sampleBuffer, source: .microphone)
    }
  }
  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) { append(sampleBuffer, source: .microphone) }
  // Also accepts deterministic fixture buffers on queue, through exactly the production path.
  func append(_ sample: CMSampleBuffer, source: Source) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard accepting, failure == nil, CMSampleBufferDataIsReady(sample) else { return }
    if source == .video { latestObservedVideo = sample }
    let original = CMSampleBufferGetPresentationTimeStamp(sample).seconds
    guard original.isFinite else { return }
    if source == .video { timeline.begin(at: original) }
    guard let time = timeline.mapped(original), time > (lastTimes[source] ?? -1) else { return }
    let input = source == .video ? video : (source == .computer ? computer : microphone)
    guard let input else { return }
    guard input.isReadyForMoreMediaData else {
      dropped += 1
      return
    }
    do {
      let shifted = try Self.retime(sample, offset: original - time)
      guard input.append(shifted) else { throw writer.error ?? RecordingError.message("录屏写入失败。") }
      lastTimes[source] = time
      if source == .video {
        lastVideo = sample
        frameCount += 1
        onProgress?(time)
      } else {
        audioCounts[source == .computer ? 0 : 1] += 1
      }
    } catch {
      failure = error
      onFailure?(error)
    }
  }
  func pause(at time: Double = CMClockGetTime(CMClockGetHostTimeClock()).seconds) {
    queue.async { self.timeline.pause(at: time) }
  }
  func resume(at time: Double = CMClockGetTime(CMClockGetHostTimeClock()).seconds) {
    queue.async {
      guard self.timeline.pausedAt != nil else { return }
      self.timeline.resume(at: time)
      // A static desktop may send no complete frame after resume. Use its latest observed frame at the resume boundary.
      if let sample = self.latestObservedVideo,
        let current = try? Self.retime(
          sample, offset: CMSampleBufferGetPresentationTimeStamp(sample).seconds - time)
      {
        self.append(current, source: .video)
      }
    }
  }
  func finish(at stop: Double = CMClockGetTime(CMClockGetHostTimeClock()).seconds) async throws
    -> [String: Any]
  {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        guard self.accepting else {
          continuation.resume(throwing: RecordingError.message("录屏已结束。"))
          return
        }
        self.accepting = false
        guard self.writer.status == .writing else {
          self.lastVideo = nil
          self.latestObservedVideo = nil
          continuation.resume(
            throwing: self.writer.error ?? self.failure ?? RecordingError.message("编码已中断，原片保留供恢复。"))
          return
        }
        // Repeating the final frame extends still content to the actual stop time.
        let end =
          self.timeline.pausedAt.flatMap { paused in
            self.timeline.origin.map { origin in paused - origin - self.timeline.pausedDuration }
          } ?? self.timeline.mapped(stop) ?? self.lastTimes[.video] ?? 0
        if let last = self.lastVideo, end > (self.lastTimes[.video] ?? 0) + 1 / Double(self.fps),
          self.video.isReadyForMoreMediaData,
          let tail = try? Self.retime(
            last,
            offset: CMSampleBufferGetPresentationTimeStamp(last).seconds
              - max(0, end - 1 / Double(self.fps)))
        {
          _ = self.video.append(tail)
        }
        if self.frameCount == 0 {
          self.writer.cancelWriting()
          continuation.resume(throwing: self.failure ?? RecordingError.message("没有收到有效画面，请重新选择范围。"))
          return
        }
        [self.video, self.computer, self.microphone].compactMap { $0 }.forEach {
          $0.markAsFinished()
        }
        self.writer.endSession(
          atSourceTime: CMTime(seconds: max(end, 1 / Double(self.fps)), preferredTimescale: 60000))
        self.writer.finishWriting {
          self.queue.async {
            self.lastVideo = nil
            self.latestObservedVideo = nil
            if self.writer.status == .completed {
              continuation.resume(returning: [
                "videoFrames": self.frameCount, "sourceStartHostSeconds": self.timeline.origin ?? 0,
                "pausedSeconds": self.timeline.pausedDuration,
                "streamFrameStatuses": Dictionary(
                  uniqueKeysWithValues: self.statuses.map { (String($0.key), $0.value) }),
                "computerBuffers": self.audioCounts[0],
                "microphoneBuffers": self.audioCounts[1], "droppedBuffers": self.dropped,
                "seconds": end,
              ])
            } else {
              continuation.resume(
                throwing: self.writer.error ?? self.failure ?? RecordingError.message("录屏文件未能完成。"))
            }
          }
        }
      }
    }
  }
  func elapsed() async -> Double {
    await withCheckedContinuation { c in
      queue.async {
        c.resume(
          returning: self.timeline.pausedAt.flatMap { paused in
            self.timeline.origin.map { paused - $0 - self.timeline.pausedDuration }
          } ?? self.timeline.mapped(CMClockGetTime(CMClockGetHostTimeClock()).seconds) ?? 0)
      }
    }
  }
  func cancel() {
    queue.async {
      self.accepting = false
      self.writer.cancelWriting()
      self.lastVideo = nil
      self.latestObservedVideo = nil
    }
  }
  private static func retime(_ sample: CMSampleBuffer, offset: Double) throws -> CMSampleBuffer {
    var count = 0
    CMSampleBufferGetSampleTimingInfoArray(
      sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
    guard count > 0 else { throw RecordingError.message("采集时间信息无效。") }
    var times = Array(repeating: CMSampleTimingInfo(), count: count)
    let status = times.withUnsafeMutableBufferPointer {
      CMSampleBufferGetSampleTimingInfoArray(
        sample, entryCount: count, arrayToFill: $0.baseAddress, entriesNeededOut: nil)
    }
    guard status == noErr else { throw RecordingError.message("无法读取采集时间。") }
    let shift = CMTime(seconds: offset, preferredTimescale: 1_000_000_000)
    for i in times.indices {
      times[i].presentationTimeStamp = CMTimeSubtract(times[i].presentationTimeStamp, shift)
      if times[i].decodeTimeStamp.isValid {
        times[i].decodeTimeStamp = CMTimeSubtract(times[i].decodeTimeStamp, shift)
      }
    }
    var result: CMSampleBuffer?
    let copy = times.withUnsafeBufferPointer {
      CMSampleBufferCreateCopyWithNewTiming(
        allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: count,
        sampleTimingArray: $0.baseAddress!, sampleBufferOut: &result)
    }
    guard copy == noErr, let result else { throw RecordingError.message("无法同步音视频时间。") }
    return result
  }
}
enum RecordingError: LocalizedError {
  case message(String)
  var errorDescription: String? {
    if case .message(let text) = self { return text }
    return nil
  }
}
