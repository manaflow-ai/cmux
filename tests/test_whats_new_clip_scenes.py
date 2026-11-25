"""Every capture scene a What's New clip or a media tour renders is one the app defines.

Regression: #51244's clip 36047-chief-cloud-computer rendered `home-chief-profile-details` and
`home-chief-profile-computer`, scenes the app never had, so every tour failed it with
"debug.scene.render: unknown scene" and the highlight stayed without media.
"""
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTROL = ROOT / "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Control"
SPECS = [*sorted((ROOT / "release-notes/next/clips").glob("*.json")),
         *sorted((ROOT / "scripts/cmux-next/media/tours").glob("*.json"))]


def defined_scenes():
    """Scene names from `CaptureSceneDefinition(name: …)`: a literal, or a `static let` it names."""
    source = "\n".join(p.read_text() for p in sorted(CONTROL.glob("CaptureSceneRegistry*.swift")))
    constants = dict(re.findall(r'static let (\w+) = "([^"]+)"', source))
    names = set()
    for literal, constant in re.findall(r'CaptureSceneDefinition\(\s*name:\s*(?:"([^"]+)"|(\w+))', source):
        names.add(literal or constants[constant])
    return names


def rendered_scenes(node):
    """Every `debug.scene.render` call's scene in a spec, wherever it sits."""
    if isinstance(node, dict):
        if node.get("method") == "debug.scene.render":
            yield (node.get("params") or {}).get("scene")
        for value in node.values():
            yield from rendered_scenes(value)
    elif isinstance(node, list):
        for value in node:
            yield from rendered_scenes(value)


class ClipScenesExist(unittest.TestCase):
    def test_the_registry_reads_both_literal_and_constant_names(self):
        scenes = defined_scenes()
        self.assertIn("home-chief", scenes)
        self.assertIn("home-chief-long-draft", scenes)

    def test_every_rendered_scene_is_defined(self):
        scenes = defined_scenes()
        missing = [f"{spec.relative_to(ROOT)}: {scene}"
                   for spec in SPECS for scene in rendered_scenes(json.loads(spec.read_text()))
                   if scene not in scenes]
        self.assertEqual(missing, [], "clip specs render scenes the app does not define")


if __name__ == "__main__":
    unittest.main()
