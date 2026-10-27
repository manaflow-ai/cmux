#!/usr/bin/env python3
"""The permission rows of chromium_host_native_ui.py (p01-process-062, chromium-host-bench.py --native-ui) against a
fake app: the page's request, cmux's prompt bar (`debug.browser.prompts`), the Block answer and the page's result.
A correct app passes the camera, microphone and location rows. The notifications row fails while Chromium has no
Notification API. An app that never asks (Chromium's hidden bubble), a child process with a window on screen, an
answer that never reaches the page and a build without `debug.browser.prompts` each fail the rows they break.
Runs anywhere (no app). Run: python3 -I scripts/cmux-next/tests/test_chromium_host_native_ui_permissions.py"""
import os, re, sys, unittest, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import chromium_host_native_ui as native  # noqa: E402

# The kind `debug.browser.prompts` reports (String(describing:) of BrowserPromptKind) for each request.
KINDS = {
    "camera": "permission(CmuxNextBrowserCore.BrowserPermissionKind.capabilities([CmuxNextBrowserCore.BrowserSiteCapability.camera]))",
    "microphone": "permission(CmuxNextBrowserCore.BrowserPermissionKind.capabilities([CmuxNextBrowserCore.BrowserSiteCapability.microphone]))",
    "location": "permission(CmuxNextBrowserCore.BrowserPermissionKind.location)",
    "notifications": "permission(CmuxNextBrowserCore.BrowserPermissionKind.notifications)",
}
# What the page hears after Block.
BLOCKED = {"camera": {"state": "error", "name": "NotAllowedError"}, "microphone": {"state": "error", "name": "NotAllowedError"},
           "location": {"state": "error", "code": 1}, "notifications": {"state": "answered", "result": "denied"}}


class FakeApp:
    """The app as the rows see it. `asks` is False when the request never reaches the prompt bar; `notifications`
    is True when the page has the Notification API; `ignores_answer` leaves the page's request pending; `prompts`
    is False for a build without `debug.browser.prompts`; `leftover` is a question already open."""

    def __init__(self, asks=True, notifications=False, ignores_answer=False, prompts=True, leftover=None):
        self.asks, self.notifications, self.ignores_answer, self.has_prompts = asks, notifications, ignores_answer, prompts
        self.pending = [{"kind": KINDS[leftover], "origin": "http://127.0.0.1:1"}] if leftover else []
        self.asking = {}
        self.page = {}
        self.answers = []

    def rpc(self, method, params=None, timeout=60):
        params = params or {}
        if method == "action.run":
            return {"ok": True}
        if method == "debug.browser.prompts":
            if not self.has_prompts:
                return {"error": "unknown method"}
            result = {}
            if "respond" in params:
                first = self.pending.pop(0) if self.pending else None
                result["responded"] = first is not None
                self.answers.append(params["respond"])
                name = self.asking.pop(first["kind"], None) if first else None
                if name and params["respond"] == "deny" and not self.ignores_answer:
                    self.page[name] = dict(BLOCKED[name])
            result["prompts"] = list(self.pending)
            return result
        raise AssertionError(f"unexpected method {method}")

    def page_eval(self, script):
        if "readyState" in script:
            return True
        started = re.fullmatch(r'ask\("(\w+)"\), true', script)
        if started:
            name = started.group(1)
            if name == "notifications" and not self.notifications:
                self.page[name] = {"state": "unavailable"}
                return True
            self.page[name] = {"state": "pending"}
            if self.asks:
                self.pending.append({"kind": KINDS[name], "origin": "http://127.0.0.1:1"})
                self.asking[KINDS[name]] = name
            return True
        read = re.fullmatch(r'window\.__perm && window\.__perm\["(\w+)"\]', script)
        if read:
            return self.page.get(read.group(1))
        raise AssertionError(f"unexpected script {script!r}")


def instant_wait(check, seconds, step=0.1):
    """The bench's wait() with no sleeping: the fake app answers at once or never."""
    for _ in range(3):
        value = check()
        if value:
            return value
    return None


def rows(app, windows=lambda: []):
    return native.permission_rows(app.rpc, instant_wait, app.page_eval, "http://127.0.0.1:1/", windows)


class PermissionRows(unittest.TestCase):
    def test_a_correct_app_passes_camera_microphone_and_location(self):
        result = rows(FakeApp())
        for name in ("permission_camera", "permission_microphone", "permission_location"):
            self.assertTrue(result[name]["ok"], result[name])
            self.assertEqual(result[name]["child_windows_on_screen"]["count"], 0)

    def test_notifications_fail_while_chromium_has_no_notification_api(self):
        row = rows(FakeApp())["permission_notifications"]
        self.assertFalse(row["ok"])
        self.assertIn("disable-notifications", row["not_run"])

    def test_notifications_pass_once_the_page_can_ask(self):
        self.assertTrue(rows(FakeApp(notifications=True))["permission_notifications"]["ok"])

    def test_a_request_the_prompt_bar_never_asks_fails(self):
        result = rows(FakeApp(asks=False))
        for name in ("permission_camera", "permission_microphone", "permission_location"):
            self.assertFalse(result[name]["ok"])
            self.assertIsNone(result[name]["prompt"])

    def test_a_child_process_window_on_screen_fails(self):
        bubble = [{"pid": 42, "layer": 0, "alpha": 1.0, "bounds": [10, 10, 320, 160]}]
        result = rows(FakeApp(), windows=lambda: bubble)
        self.assertFalse(result["permission_camera"]["ok"])
        self.assertEqual(result["permission_camera"]["child_windows_on_screen"]["count"], 1)

    def test_unreadable_windows_fail(self):
        self.assertFalse(rows(FakeApp(), windows=lambda: None)["permission_location"]["ok"])

    def test_an_answer_the_page_never_hears_fails(self):
        self.assertFalse(rows(FakeApp(ignores_answer=True))["permission_microphone"]["ok"])

    def test_a_build_without_the_prompt_call_says_so(self):
        result = rows(FakeApp(prompts=False))
        self.assertEqual(set(result), {row for row, _, _, _ in native.PERMISSION_ROWS})
        for row in result.values():
            self.assertFalse(row["ok"])
            self.assertIn("debug.browser.prompts", row["not_run"])

    def test_a_question_left_open_is_cancelled_first(self):
        app = FakeApp(leftover="location")
        result = rows(app)
        self.assertEqual(app.answers[0], "cancel")
        self.assertTrue(result["permission_camera"]["ok"], result["permission_camera"])

    def test_the_page_is_served_from_a_loopback_origin(self):
        url = native.serve_permission_page()
        self.assertTrue(url.startswith("http://127.0.0.1:"))
        with urllib.request.urlopen(url, timeout=10) as reply:
            body = reply.read().decode()
        self.assertIn("function ask(name)", body)

    def test_the_launch_turns_on_the_feature_and_the_fake_devices(self):
        env = native.launch_env([])
        self.assertIn("chromiumPermissionPromptsFromData", env["CMUX_ENABLE_FEATURES"].split(","))
        self.assertEqual(env["CMUX_NEXT_CEF_EXTRA_SWITCHES"], "use-fake-device-for-media-stream")


if __name__ == "__main__":
    unittest.main()
