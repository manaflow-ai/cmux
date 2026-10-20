"""Unit tests for the release-media scene checks, encoder helpers, and TS patcher.

    python3 tests/test_release_media.py -v
"""
import glob
import json
import os
import sys
import unittest

TOOL = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts", "release-media")
sys.path.insert(0, TOOL)

import host_agent  # noqa: E402
import release_media  # noqa: E402

SCENES = sorted(glob.glob(os.path.join(TOOL, "scenes", "*", "*.json")))

MEDIA_TS = """\
/** Header with `{braces}` in a comment. */
export const changelogMedia: Record<string, VersionMedia> = {
  "0.2.0": {
    title: "Two",
    features: [
      {
        title: "Alpha",
        description:
          "Alpha text with {braces} and a \\"quote\\".",
        tryIt: "Run `cmux alpha`.",
      },
      {
        title: "Beta",
        description: "Beta text.",
        image: "/changelog/0.2.0-beta.png",
      },
    ],
  },
  "0.1.0": {
    title: "One",
    features: [
      {
        title: "Alpha",
        description: "Old alpha.",
      },
    ],
  },
};
"""

VIDEO = {
    "video": {
        "src": "/changelog/0.2.0/alpha.mp4",
        "webm": "/changelog/0.2.0/alpha.webm",
        "poster": "/changelog/0.2.0/alpha-poster.png",
    }
}


def minimal_scene(**overrides):
    scene = {
        "version": "0.2.0",
        "feature": "Alpha",
        "slug": "alpha",
        "window": {"width": 1200, "height": 675},
        "capture": {"type": "clip", "seconds": 8, "during": [{"at": 3, "sleep": 1}]},
    }
    scene.update(overrides)
    return scene


class SceneValidationTests(unittest.TestCase):
    def test_checked_in_scenes_are_valid(self):
        self.assertTrue(SCENES)
        for path in SCENES:
            with self.subTest(path=path):
                scene = release_media.load_scene(path)
                folder = os.path.basename(os.path.dirname(path))
                self.assertEqual(folder, scene["version"])
                self.assertEqual(os.path.basename(path), scene["slug"] + ".json")

    def test_rejects_bad_scenes(self):
        cases = {
            "unknown key": minimal_scene(extra=1),
            "long clip": minimal_scene(capture={"type": "clip", "seconds": 12}),
            "bad slug": minimal_scene(slug="Alpha Clip"),
            "step outside clip": minimal_scene(capture={"type": "clip", "seconds": 6, "during": [{"at": 7, "sleep": 1}]}),
            "two step kinds": minimal_scene(setup=[{"sleep": 1, "cmux": ["ping"]}]),
            "bad matte": minimal_scene(output={"matte": "white"}),
            "no window size": minimal_scene(window={"width": 800}),
        }
        for name, scene in cases.items():
            with self.subTest(name), self.assertRaises(release_media.SceneError):
                release_media.validate_scene(scene)

    def test_accepts_screenshot(self):
        release_media.validate_scene(minimal_scene(capture={"type": "screenshot"}))


class PatchMediaTests(unittest.TestCase):
    def test_adds_video_to_the_right_version_and_feature(self):
        patched = release_media.patch_media_ts(MEDIA_TS, "0.2.0", "Alpha", VIDEO)
        self.assertIn('          src: "/changelog/0.2.0/alpha.mp4",', patched)
        self.assertEqual(patched.count("video: {"), 1)
        # The older release's feature with the same title is untouched.
        self.assertIn('        description: "Old alpha.",\n      },', patched)
        self.assertLess(patched.index("video: {"), patched.index('"0.1.0"'))
        self.assertEqual(patched.replace(self.video_lines(), ""), MEDIA_TS)

    def test_replaces_existing_media(self):
        patched = release_media.patch_media_ts(MEDIA_TS, "0.2.0", "Beta", {"image": "/changelog/0.2.0/beta.png"})
        self.assertNotIn("0.2.0-beta.png", patched)
        self.assertIn('        image: "/changelog/0.2.0/beta.png",\n      },', patched)
        twice = release_media.patch_media_ts(patched, "0.2.0", "Beta", VIDEO)
        again = release_media.patch_media_ts(twice, "0.2.0", "Beta", VIDEO)
        self.assertEqual(twice, again)
        self.assertNotIn("image:", twice.split('"0.1.0"')[0].split('title: "Beta"')[1])

    def test_adds_try_it_only_when_missing(self):
        kept = release_media.patch_media_ts(MEDIA_TS, "0.2.0", "Alpha", VIDEO, try_it="Other")
        self.assertNotIn("Other", kept)
        added = release_media.patch_media_ts(MEDIA_TS, "0.2.0", "Beta", VIDEO, try_it="Run `x`.")
        self.assertIn('        tryIt: "Run `x`.",', added)

    def test_missing_version_or_feature_fails(self):
        with self.assertRaises(SystemExit):
            release_media.patch_media_ts(MEDIA_TS, "9.9.9", "Alpha", VIDEO)
        with self.assertRaises(SystemExit):
            release_media.patch_media_ts(MEDIA_TS, "0.2.0", "Gamma", VIDEO)

    def test_real_file_stays_balanced(self):
        with open(release_media.MEDIA_TS) as handle:
            text = handle.read()
        anchor = text.index("export const changelogMedia")
        start = text.index("{", text.index("=", anchor))
        release_media.matching_brace(text, start)
        for path in SCENES:
            scene = release_media.load_scene(path)
            patched = release_media.patch_media_ts(text, scene["version"], scene["feature"], VIDEO)
            release_media.matching_brace(patched, start)

    @staticmethod
    def video_lines():
        return (
            "        video: {\n"
            '          src: "/changelog/0.2.0/alpha.mp4",\n'
            '          webm: "/changelog/0.2.0/alpha.webm",\n'
            '          poster: "/changelog/0.2.0/alpha-poster.png",\n'
            "        },\n"
        )


class EncoderHelperTests(unittest.TestCase):
    def test_concat_list_holds_each_frame_until_the_next(self):
        frames = [{"file": "a.png", "t": 0.0}, {"file": "b.png", "t": 0.2}, {"file": "c.png", "t": 0.5}]
        listing = release_media.concat_list(frames, "/f", 1.0).splitlines()
        self.assertEqual(listing[0], "ffconcat version 1.0")
        self.assertEqual(listing[1:7], [
            "file '/f/a.png'", "duration 0.200",
            "file '/f/b.png'", "duration 0.300",
            "file '/f/c.png'", "duration 0.500",
        ])
        self.assertEqual(listing[-1], "file '/f/c.png'")

    def test_fit_filter_never_upscales(self):
        self.assertEqual(release_media.fit_filter(1200, 1200), "crop=trunc(iw/2)*2:trunc(ih/2)*2:0:0")
        self.assertTrue(release_media.fit_filter(2400, 1600).startswith("scale=1600:-1"))


class HostAgentTests(unittest.TestCase):
    def test_deep_merge_keeps_unrelated_settings(self):
        base = {"app": {"appearance": "system", "language": "en"}, "shortcuts": {"x": 1}}
        merged = host_agent.deep_merge(base, {"app": {"appearance": "dark"}})
        self.assertEqual(merged, {"app": {"appearance": "dark", "language": "en"}, "shortcuts": {"x": 1}})
        self.assertEqual(base["app"]["appearance"], "system")

    def test_settings_are_read_as_jsonc(self):
        text = '// cmux template\n{\n  "a": "x // kept, }", /* note */\n  "b": [1, 2,],\n}\n'
        self.assertEqual(host_agent.parse_jsonc(text), {"a": "x // kept, }", "b": [1, 2]})
        self.assertEqual(host_agent.parse_jsonc("// only a comment\n"), {})
        # cmux's own template: a trailing comma before commented-out entries.
        template = '\ufeff{\n  "schemaVersion": 1,\n  // "app": {\n  //   "appearance": "system"\n  // }\n}\n'
        self.assertEqual(host_agent.parse_jsonc(template), {"schemaVersion": 1})
        with self.assertRaises(host_agent.AgentError):
            host_agent.parse_jsonc("{ nope }")

    def test_steps_substitute_and_save_handles(self):
        calls = []

        def cmux(*args):
            calls.append(args)
            return "OK surface:7 workspace:1"

        names = {"window": "W-1"}
        host_agent.run_step({"cmux": ["new-split", "right", "--window", "{window}"], "save": "right"}, cmux, None, names)
        host_agent.run_step({"cmux": ["send", "--surface", "{right}", "ls\\n"]}, cmux, None, names)
        self.assertEqual(calls, [("new-split", "right", "--window", "W-1"), ("send", "--surface", "surface:7", "ls\\n")])

    def test_save_requires_an_ok_handle(self):
        with self.assertRaises(host_agent.AgentError):
            host_agent.run_step({"cmux": ["new-window"], "save": "w"}, lambda *a: "ERROR nope", None, {})

    def test_settings_guard_restores_original_bytes(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "cmux.json")
            original = b'{\n  "app": {"appearance": "system"}\n}\n'
            with open(path, "wb") as handle:
                handle.write(original)
            saved = host_agent.CMUX_JSON
            host_agent.CMUX_JSON = path
            try:
                guard = host_agent.SettingsGuard()
                guard.apply({"app": {"appearance": "dark"}})
                with open(path) as handle:
                    self.assertEqual(json.load(handle)["app"]["appearance"], "dark")
                guard.restore()
                with open(path, "rb") as handle:
                    self.assertEqual(handle.read(), original)
            finally:
                host_agent.CMUX_JSON = saved


if __name__ == "__main__":
    unittest.main()
