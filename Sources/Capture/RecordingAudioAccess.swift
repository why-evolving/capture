import AVFoundation
import CaptureCore

/// Injectable authorization boundary. Disabled microphones never query, request or connect input.
@MainActor struct RecordingAudioAccess {
  var status: () -> AVAuthorizationStatus
  var request: () async -> Bool
  var validateDevice: (String?) throws -> Void
  static var live: Self {
    Self(
      status: { AVCaptureDevice.authorizationStatus(for: .audio) },
      request: { await AVCaptureDevice.requestAccess(for: .audio) },
      validateDevice: { _ = try RecordingEngine.microphone(id: $0) })
  }
  func prepare(_ options: RecordingOptions) async throws {
    guard options.microphone else { return }
    let current = status()
    let granted: Bool
    if current == .authorized {
      granted = true
    } else if current == .notDetermined {
      granted = await request()
    } else {
      granted = false
    }
    guard granted else { throw RecordingError.message("麦克风未获授权。请在系统设置允许，或关闭麦克风后重试。") }
    try validateDevice(options.microphoneID)
  }
}
