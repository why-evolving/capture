#!/usr/bin/env python3
"""Fail closed when a requested native check did not actually execute."""
import argparse
import json
import math
from pathlib import Path


def validate(directory: Path, workflow_only: bool = False, editor_tabs: bool = False, login_items: bool = False) -> dict:
    for marker in ("checks-blocked.json", "checks-failure.json"):
        if (directory / marker).exists():
            raise ValueError((directory / marker).read_text())
    if login_items:
        report = json.loads((directory / "login-checks.json").read_text())
        checks = report.get("checks", [])
        if report.get("result") != "passed" or len(checks) != 7 or len(set(checks)) != 7:
            raise ValueError("Login item regression checks are incomplete")
        for flag in ["generalClipboardModified", "screenCaptureAttempted", "systemLoginItemModified"]:
            if report.get(flag) is not False:
                raise ValueError("Login item fixture isolation was not verified")
        return report
    if editor_tabs:
        report = json.loads((directory / "editor-performance.json").read_text())
        rows = report.get("measurements", [])
        expected = {(cycle, tab) for cycle in range(6) for tab in ["背景", "标注", "布局", "效果", "导出"]}
        if report.get("result") != "passed" or len(rows) != 30 or {(r["cycle"], r["tab"]) for r in rows} != expected:
            raise ValueError("Editor click checks did not complete all 30 transitions")
        if report.get("inputMode") != "local-mouse-events" or not report.get("previewReused") or not report.get("editsUnchanged"):
            raise ValueError("Editor click routing or preview reuse was not verified")
        if report.get("generalClipboardModified") is not False or report.get("screenCaptureAttempted") is not False:
            raise ValueError("Editor fixture isolation was not verified")
        return report
    report = json.loads((directory / ("workflow-checks.json" if workflow_only else "checks.json")).read_text())
    if report.get("result") != "passed" or not report.get("checks"):
        raise ValueError("Native checks were not completed successfully")
    if report.get("generalClipboardModified") is not False:
        raise ValueError("Private clipboard isolation was not verified")
    if workflow_only:
        if report.get("screenCaptureAttempted") is not False:
            raise ValueError("An offline workflow check unexpectedly captured the screen")
    elif report.get("ownWindowCapture", {}).get("result") != "passed" or report.get("screenCaptureAttempted") is not True:
        raise ValueError("Requested screen capture was skipped or blocked; this is not a pass")
    return report



def validate_recording(directory: Path, require_screen: bool = True) -> dict:
    for marker in ("checks-blocked.json", "checks-failure.json"):
        if (directory / marker).exists():
            raise ValueError((directory / marker).read_text())
    report = json.loads((directory / "recording-checks.json").read_text())
    needed = {"recording-four-audio-combinations", "recording-two-sources-single-aac-mix",
              "recording-zero-volume-silence", "recording-pause-video-and-audio-excluded",
              "recording-pause-duration-and-final-frame", "recording-independent-carbon-routing-and-suspension",
              "recording-mic-disabled-does-not-authorize", "recording-mic-denial-and-device-failure-preserve-choice",
              "recording-failed-export-retains-recoverable-source", "recording-atomic-save-and-private-file-clipboard",
              "recording-restart-index-and-delete-boundary", "recording-symlink-and-path-rejection",
              "recording-setup-result-error-minimum-layout", "recording-selection-hides-static-style-actions", "recording-native-save-panel-cancel-keeps-draft"}
    if require_screen:
        needed.update({"recording-real-own-window-live-stream", "recording-real-controller-pause-resume-save", "recording-real-area-display-4k60", "recording-capture-file-choice-exclusion"})
    if report.get("result") != "passed" or not needed.issubset(report.get("checks", [])):
        raise ValueError("Recording regressions incomplete")
    if report.get("generalClipboardModified") is not False or report.get("hardwareMicrophoneCaptured") is not False:
        raise ValueError("Recording fixture isolation missing")
    rows = report.get("audioModes", [])
    if len(rows) != 5 or {r.get("mode") for r in rows} != set(range(5)):
        raise ValueError("Four audio combinations and zero gain not completed")
    for row in rows:
        if row.get("pausedGreenFrames") != 0 or not 1.85 < row.get("duration", 0) < 2.15 or row.get("audioTracks") != (0 if row["mode"] == 0 else 1):
            raise ValueError("Recording decoded media invalid")
        amplitudes = row.get("amplitudes440_880_2200Hz", [])
        if len(amplitudes) != 3 or not all(math.isfinite(x) for x in amplitudes) or amplitudes[2] >= .015:
            raise ValueError("Pause audio leaked")
        for i, enabled in enumerate([row["mode"] in (1, 3), row["mode"] in (2, 3)]):
            if not (amplitudes[i] > .03 if enabled else amplitudes[i] < .015):
                raise ValueError("Recording source mix does not match switches")
    if require_screen and (report.get("screenCaptureAttempted") is not True or report.get("liveCapture", {}).get("result") != "passed"):
        raise ValueError("Live screen recording skipped or blocked")
    return report



def validate_quick_recording(directory: Path) -> dict:
    for marker in ("checks-blocked.json", "checks-failure.json"):
        if (directory / marker).exists(): raise ValueError((directory / marker).read_text())
    report=json.loads((directory/"quick-recording-checks.json").read_text())
    needed={"quick-entry-bypasses-setup","quick-release-starts-countdown","quick-inline-options-and-menu-level","quick-adjust-preserves-range-and-default","quick-drag-stays-in-selection","quick-denial-recovers-inline","quick-cancel-invalidates-old-countdown","quick-window-retains-identity","quick-fullscreen-to-area","quick-explicit-settings-and-start","quick-own-window-produces-video-once","quick-persistent-adjustment-setting","quick-all-eight-handles-and-move","quick-adjustment-return-starts-in-place"}
    if report.get("result")!="passed" or (set(report.get("checks",[]))!=needed or len(report.get("checks",[]))!=len(needed)): raise ValueError("Quick recording checks incomplete")
    if report.get("screenCaptureAttempted") is not True or report.get("generalClipboardModified") is not False or report.get("hardwareMicrophoneCaptured") is not False: raise ValueError("Quick capture fixture isolation missing")
    if report.get("transitions",[]).count("recording")!=1: raise ValueError("Quick flow duplicate or missing recording")
    for name in ["quick-ready.png","quick-more.png","quick-adjusted.png","quick-error.png","quick-output.mp4"]:
        if not (directory/name).is_file(): raise ValueError("Quick evidence missing: "+name)
    return report


def self_test() -> None:
    import tempfile
    import unittest

    class ReportTests(unittest.TestCase):
        def setUp(self):
            self.temp = tempfile.TemporaryDirectory(prefix="capture-report-tests-")
            self.addCleanup(self.temp.cleanup)
            self.directory = Path(self.temp.name)
            self.report = {"result": "passed", "checks": ["real-window"], "generalClipboardModified": False,
                           "screenCaptureAttempted": True, "ownWindowCapture": {"result": "passed"}}

        def write(self):
            (self.directory / "checks.json").write_text(json.dumps(self.report))

        def test_actual_capture_passes(self):
            self.write()
            self.assertEqual(validate(self.directory)["result"], "passed")

        def test_permission_denial_cannot_pass(self):
            self.report.update(screenCaptureAttempted=False, ownWindowCapture={"result": "permission-required"})
            self.write()
            with self.assertRaises(ValueError):
                validate(self.directory)

        def test_skip_cannot_pass(self):
            self.report.update(screenCaptureAttempted=False, ownWindowCapture={"result": "not-requested"})
            self.write()
            with self.assertRaises(ValueError):
                validate(self.directory)

        def test_failure_or_block_overrides_stale_pass(self):
            self.write()
            for marker in ("checks-blocked.json", "checks-failure.json"):
                with self.subTest(marker=marker):
                    path = self.directory / marker
                    path.write_text('{"result":"blocked"}')
                    with self.assertRaises(ValueError):
                        validate(self.directory)
                    path.unlink()

        def test_missing_report_cannot_pass(self):
            with self.assertRaises(FileNotFoundError):
                validate(self.directory)

        def test_offline_workflow_requires_isolation(self):
            self.report["screenCaptureAttempted"] = False
            path = self.directory / "workflow-checks.json"
            path.write_text(json.dumps(self.report))
            self.assertEqual(validate(self.directory, True)["result"], "passed")
            self.report["generalClipboardModified"] = True
            path.write_text(json.dumps(self.report))
            with self.assertRaises(ValueError):
                validate(self.directory, True)

        def test_editor_requires_complete_mouse_event_evidence(self):
            report = {"result": "passed", "inputMode": "local-mouse-events", "previewReused": True,
                      "editsUnchanged": True, "generalClipboardModified": False, "screenCaptureAttempted": False,
                      "measurements": [{"cycle": cycle, "tab": tab} for cycle in range(6)
                                       for tab in ["背景", "标注", "布局", "效果", "导出"]]}
            path = self.directory / "editor-performance.json"
            path.write_text(json.dumps(report))
            self.assertEqual(validate(self.directory, editor_tabs=True)["result"], "passed")
            for changes in [{"inputMode": "binding"}, {"previewReused": False},
                            {"measurements": report["measurements"][:-1] + [report["measurements"][0]]}]:
                with self.subTest(changes=changes):
                    path.write_text(json.dumps(dict(report, **changes)))
                    with self.assertRaises(ValueError):
                        validate(self.directory, editor_tabs=True)

        def test_login_fixture_requires_isolation_and_complete_checks(self):
            report = {"result": "passed", "checks": [f"login-{i}" for i in range(7)],
                      "generalClipboardModified": False, "screenCaptureAttempted": False, "systemLoginItemModified": False}
            path = self.directory / "login-checks.json"
            path.write_text(json.dumps(report))
            self.assertEqual(validate(self.directory, login_items=True)["result"], "passed")
            for changes in [{"systemLoginItemModified": True}, {"checks": []}, {"result": "blocked"}]:
                path.write_text(json.dumps(dict(report, **changes)))
                with self.assertRaises(ValueError):
                    validate(self.directory, login_items=True)

        def test_recording_requires_complete_sources_and_no_paused_signal(self):
            checks = ["recording-four-audio-combinations", "recording-two-sources-single-aac-mix", "recording-zero-volume-silence", "recording-pause-video-and-audio-excluded", "recording-pause-duration-and-final-frame", "recording-independent-carbon-routing-and-suspension", "recording-mic-disabled-does-not-authorize", "recording-mic-denial-and-device-failure-preserve-choice", "recording-failed-export-retains-recoverable-source", "recording-atomic-save-and-private-file-clipboard", "recording-restart-index-and-delete-boundary", "recording-symlink-and-path-rejection", "recording-setup-result-error-minimum-layout", "recording-selection-hides-static-style-actions", "recording-native-save-panel-cancel-keeps-draft", "recording-real-own-window-live-stream", "recording-real-controller-pause-resume-save", "recording-real-area-display-4k60", "recording-capture-file-choice-exclusion"]
            report = {"result":"passed", "checks":checks, "generalClipboardModified":False, "hardwareMicrophoneCaptured":False, "screenCaptureAttempted":True, "liveCapture":{"result":"passed"}, "audioModes":[{"mode":i,"duration":2,"pausedGreenFrames":0,"audioTracks":0 if i==0 else 1,"amplitudes440_880_2200Hz":[.1 if i in (1,3) else 0,.1 if i in (2,3) else 0,0]} for i in range(5)]}
            path = self.directory / "recording-checks.json"
            path.write_text(json.dumps(report))
            self.assertEqual(validate_recording(self.directory)["result"], "passed")
            for change in [{"audioModes":report["audioModes"][:4]}, {"checks":checks[1:]}, {"screenCaptureAttempted":False}, {"hardwareMicrophoneCaptured":True}, {"liveCapture":{"result":"blocked"}}]:
                path.write_text(json.dumps(dict(report, **change)))
                with self.assertRaises(ValueError): validate_recording(self.directory)
            report["audioModes"][3]["amplitudes440_880_2200Hz"][2]=.1
            path.write_text(json.dumps(report))
            with self.assertRaises(ValueError): validate_recording(self.directory)

        def test_quick_recording_rejects_missing_steps_duplicates_or_skipped_capture(self):
            checks=["quick-entry-bypasses-setup","quick-release-starts-countdown","quick-inline-options-and-menu-level","quick-adjust-preserves-range-and-default","quick-drag-stays-in-selection","quick-denial-recovers-inline","quick-cancel-invalidates-old-countdown","quick-window-retains-identity","quick-fullscreen-to-area","quick-explicit-settings-and-start","quick-own-window-produces-video-once","quick-persistent-adjustment-setting","quick-all-eight-handles-and-move","quick-adjustment-return-starts-in-place"]
            report={"result":"passed","checks":checks,"transitions":["selecting","countdown","recording","completed"],"screenCaptureAttempted":True,"generalClipboardModified":False,"hardwareMicrophoneCaptured":False}
            for name in ["quick-ready.png","quick-more.png","quick-adjusted.png","quick-error.png","quick-output.mp4"]: (self.directory/name).write_bytes(b"report-validator-fixture")
            path=self.directory/"quick-recording-checks.json";path.write_text(json.dumps(report))
            self.assertEqual(validate_quick_recording(self.directory)["result"],"passed")
            for change in [{"checks":checks[:-1]},{"checks":checks+[checks[0]]},{"transitions":["recording","recording"]},{"screenCaptureAttempted":False},{"hardwareMicrophoneCaptured":True}]:
                path.write_text(json.dumps(dict(report,**change)))
                with self.assertRaises(ValueError): validate_quick_recording(self.directory)
            path.write_text(json.dumps(report));(self.directory/"quick-output.mp4").unlink()
            with self.assertRaises(ValueError): validate_quick_recording(self.directory)

    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ReportTests))
    if not result.wasSuccessful():
        raise SystemExit(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", nargs="?", type=Path)
    parser.add_argument("--workflow-only", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--editor-tabs", action="store_true")
    parser.add_argument("--login-items", action="store_true")
    parser.add_argument("--quick-recording", action="store_true")
    parser.add_argument("--recording", action="store_true")
    parser.add_argument("--recording-offline", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
    elif args.directory:
        report = validate_quick_recording(args.directory) if args.quick_recording else validate_recording(args.directory, not args.recording_offline) if (args.recording or args.recording_offline) else validate(args.directory, args.workflow_only, args.editor_tabs, args.login_items)
        print(f"Native report verified: {len(report.get('measurements', report.get('checks', [])))} checks")
    else:
        parser.error("directory or --self-test is required")
