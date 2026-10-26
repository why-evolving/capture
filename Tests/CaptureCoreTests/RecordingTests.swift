import Foundation
import Testing

@testable import CaptureCore

@Test func recordingDefaultsAndLegacyPreferencesRemainIndependent() throws {
  let old =
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppPreferences())) as! [String: Any]
  var legacy = old
  legacy.removeValue(forKey: "recording")
  let decoded = try JSONDecoder().decode(
    AppPreferences.self, from: JSONSerialization.data(withJSONObject: legacy))
  #expect(decoded.recording == nil)
  var legacySeven = decoded
  legacySeven.shortcut = .defaultRecording
  #expect(
    legacySeven.isValid
      && !RecordingOptions.defaults(captureShortcut: legacySeven.shortcut).shortcut.hasSameKeys(
        as: legacySeven.shortcut)
  )
  #expect(
    RecordingOptions().isValid && RecordingOptions().computerAudio && !RecordingOptions().microphone
  )
  var next = decoded
  next.recording = RecordingOptions()
  next.recording?.countdown = 5
  #expect(
    next.shortcut == decoded.shortcut && next.captureOptions == decoded.captureOptions
      && next.activeStyle == decoded.activeStyle)
  #expect(try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(next)) == next)
  next.recording?.shortcut = Shortcut(
    keyCode: next.shortcut.keyCode, modifiers: next.shortcut.modifiers, keyLabel: "Different label")
  #expect(!next.isValid)
}
@Test func recordingOutputBudgetDoesNotUpscaleAndMaintainsEvenDimensions() {
  var options = RecordingOptions()
  #expect(
    options.outputSize(source: CGSize(width: 801, height: 601)) == CGSize(width: 800, height: 600))
  #expect(
    options.outputSize(source: CGSize(width: 3840, height: 2160))
      == CGSize(width: 1920, height: 1080))
  #expect(
    options.outputSize(source: CGSize(width: 2160, height: 3840))
      == CGSize(width: 1080, height: 1920))
  options.quality = .high
  #expect(
    options.outputSize(source: CGSize(width: 7680, height: 4320))
      == CGSize(width: 3840, height: 2160))
  for size in [
    CGSize(width: 15, height: 100), CGSize(width: Double.nan, height: 100),
    CGSize(width: 40000, height: 100),
  ] { #expect(options.outputSize(source: size) == nil) }
}
@Test func recordingRejectsUnsupportedOrUnboundedOptions() {
  var o = RecordingOptions()
  o.framesPerSecond = 120
  #expect(!o.isValid)
  o = RecordingOptions()
  o.countdown = 10
  #expect(!o.isValid)
  o = RecordingOptions()
  o.microphoneVolume = .nan
  #expect(!o.isValid)
  o = RecordingOptions()
  o.computerVolume = 1.01
  #expect(!o.isValid)
  o = RecordingOptions()
  o.microphoneID = String(repeating: "a", count: 513)
  #expect(!o.isValid)
  #expect(RecordingLimits.stopReason(seconds: 3600, freeBytes: Int64.max) != nil)
  #expect(RecordingLimits.stopReason(seconds: 0, freeBytes: 0) != nil)
  #expect(RecordingLimits.stopReason(seconds: 1, freeBytes: RecordingLimits.startFreeBytes) == nil)
}
@Test func recordingPauseTimelineDropsPausedAndStaleSamples() {
  var t = RecordingTimeline()
  #expect(t.mapped(10) == nil)
  t.begin(at: 100)
  #expect(t.mapped(100) == 0 && t.mapped(101) == 1 && t.mapped(99) == nil)
  t.pause(at: 102)
  t.pause(at: 103)
  #expect(t.mapped(104) == nil)
  t.resume(at: 105)
  #expect(t.mapped(104.99) == nil && t.mapped(105) == 2 && t.mapped(106) == 3)
  t.resume(at: 106)
  #expect(t.mapped(107) == 4)
  t.pause(at: 108)
  t.resume(at: 109)
  #expect(t.mapped(109) == 5)
  #expect(t.mapped(.nan) == nil)
}
@Test func recordingPauseBeforeFirstFrameHasNoNegativeTime() {
  var t = RecordingTimeline()
  t.pause(at: 10)
  t.resume(at: 15)
  t.begin(at: 16)
  #expect(t.mapped(16) == 0 && t.mapped(17) == 1)
}

@Test func recordingResumeBoundaryAllowsOnlySubMicrosecondClockQuantization() {
  var t = RecordingTimeline()
  t.begin(at: 100)
  t.pause(at: 101)
  t.resume(at: 103)
  #expect(t.mapped(103 - 0.0000005) != nil)
  #expect(t.mapped(103 - 0.000002) == nil)
  #expect(abs((t.mapped(103 - 0.0000005) ?? -1) - 1) < 0.000001)
}

@Test func quickRecordingLegacyOptionsDefaultToReleaseWithoutChangingMediaSettings() throws {
  var old = RecordingOptions()
  old.microphone = true
  old.framesPerSecond = 60
  old.countdown = 5
  var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
  object.removeValue(forKey: "adjustBeforeRecording")
  let decoded = try JSONDecoder().decode(
    RecordingOptions.self, from: JSONSerialization.data(withJSONObject: object))
  #expect(
    !decoded.allowsRecordingAdjustment && decoded.microphone && decoded.framesPerSecond == 60
      && decoded.countdown == 5)
  var adjusted = decoded
  adjusted.adjustBeforeRecording = true
  #expect(
    try JSONDecoder().decode(RecordingOptions.self, from: JSONEncoder().encode(adjusted))
      .allowsRecordingAdjustment)
  adjusted.adjustBeforeRecording = false
  #expect(
    !adjusted.allowsRecordingAdjustment && adjusted.shortcut == old.shortcut
      && adjusted.computerVolume == old.computerVolume)
}

@Test func recordingSelectionModeIsIndependentOfScreenshotMode() throws {
  var prefs = AppPreferences()
  var screenshot = CaptureOptions()
  screenshot.adjustBeforeCapture = false
  prefs.captureOptions = screenshot
  prefs.recording = RecordingOptions()
  prefs.recording?.adjustBeforeRecording = true
  let roundTrip = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(prefs))
  #expect(roundTrip.recording?.allowsRecordingAdjustment == true)
  #expect(roundTrip.captureOptions?.allowsSelectionAdjustment == false)
  prefs.recording?.adjustBeforeRecording = false
  #expect(prefs.captureOptions?.allowsSelectionAdjustment == false)
}
