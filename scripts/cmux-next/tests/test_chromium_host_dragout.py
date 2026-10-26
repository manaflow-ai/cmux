#!/usr/bin/env python3
"""chromium_host_dragout.py, the dragout row of chromium-host-bench.py (p01-process-051), on its verdicts: a Finder drop
passes only with the link's .webloc or the image's exact bytes, a terminal drop only with the text pasted, and each
only when cmux started the session and the page's dragend saw the operation it ended with. A drop that nothing took
(dropEffect "none" after a drop the session reported as copy, the bug where the page view offered copy over a part of
the page that refuses) fails; back over the page a refused drop passes only with operation 0 and dropEffect "none".
Runs anywhere (no app). Run: python3 -I scripts/cmux-next/tests/test_chromium_host_dragout.py"""
import os, plistlib, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import chromium_host_dragout as dragout  # noqa: E402


class Verdicts(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="dragout-test-")

    def put(self, name, data):
        with open(os.path.join(self.folder, name), "wb") as out:
            out.write(data)

    def test_the_page_and_its_image(self):
        png = dragout.image_png()
        self.assertTrue(png.startswith(b"\x89PNG\r\n\x1a\n"))
        url = dragout.write_page(self.folder)
        self.assertTrue(url.startswith("file://") and url.endswith("drag-out.html"))
        with open(os.path.join(self.folder, dragout.IMAGE_NAME), "rb") as image:
            self.assertEqual(image.read(), png)
        self.assertIn(dragout.HREF, dragout.PAGE)

    def test_a_finder_link_drop_needs_the_webloc_of_the_link(self):
        before = os.listdir(self.folder)
        self.put("cmux drag-out link.webloc", plistlib.dumps({"URL": dragout.HREF}))
        ok = dragout.finder_verdict("link", self.folder, before, "copy", 1, 1, b"")
        self.assertTrue(ok["pass"], ok)
        wrong = dragout.finder_verdict("link", self.folder, os.listdir(self.folder), "copy", 1, 1, b"")
        self.assertFalse(wrong["pass"], "no new file")

    def test_a_finder_image_drop_needs_the_images_bytes(self):
        png = dragout.image_png()
        before = os.listdir(self.folder)
        self.put("drag-out.png", png[:-1])
        self.assertFalse(dragout.finder_verdict("image", self.folder, before, "copy", 1, 1, png)["pass"], "truncated")
        self.put("drag-out 2.png", png)
        self.assertTrue(dragout.finder_verdict("image", self.folder, before, "copy", 1, 1, png)["pass"])

    def test_a_drop_needs_cmuxs_session_and_the_ended_operations_drop_effect(self):
        before = os.listdir(self.folder)
        self.put("a.webloc", plistlib.dumps({"URL": dragout.HREF}))
        self.assertFalse(dragout.finder_verdict("link", self.folder, before, "copy", 0, 1, b"")["pass"],
                         "Chromium's own session, not cmux's")
        self.assertFalse(dragout.finder_verdict("link", self.folder, before, "none", 1, 1, b"")["pass"],
                         "dragend saw none for a taken drop")
        self.assertFalse(dragout.finder_verdict("link", self.folder, before, "copy", 1, 0, b"")["pass"],
                         "the session ended with no operation")
        self.assertTrue(dragout.finder_verdict("link", self.folder, before, "link", 1, 2, b"")["pass"])

    def test_a_terminal_drop_needs_the_pasted_text(self):
        self.assertTrue(dragout.terminal_verdict(dragout.HREF, "$ ", f"$ {dragout.HREF}", "copy", 1, 1)["pass"])
        self.assertFalse(dragout.terminal_verdict(dragout.HREF, f"$ {dragout.HREF}", f"$ {dragout.HREF}", "copy", 1, 1)["pass"],
                         "the text was there before the drop")
        self.assertFalse(dragout.terminal_verdict(dragout.IMAGE_NAME, "$ ", "$ ", "copy", 1, 1)["pass"])

    def test_back_over_the_page(self):
        zone = {"probe": "link", "uri": dragout.HREF}
        self.assertTrue(dragout.page_verdict("page_zone", zone, "copy", 1, 1, 3)["pass"])
        self.assertFalse(dragout.page_verdict("page_zone", {"probe": "", "uri": dragout.HREF}, "copy", 1, 1, 3)["pass"],
                         "the page's own drag data is lost")
        self.assertFalse(dragout.page_verdict("page_zone", zone, "copy", 1, 1, 0)["pass"], "no answer from the page")
        self.assertTrue(dragout.page_verdict("page_refused", None, "none", 1, 0, 2)["pass"])
        self.assertFalse(dragout.page_verdict("page_refused", None, "copy", 1, 1, 2)["pass"],
                         "a copy offered where the page refuses: the drop ended as copy")

    def test_drop_effects_and_sessions(self):
        self.assertEqual(dragout.effect_of(0), "none")
        self.assertEqual(dragout.effect_of(1 | 16), "copy")
        self.assertEqual(dragout.effect_of(16), "move")
        self.assertEqual(dragout.drop_end([["link", "copy"], ["img", "none"], ["link", "none"]], "link", 1), "none")
        self.assertIsNone(dragout.drop_end([["link", "copy"]], "link", 1))
        self.assertEqual(dragout.session({"sessions": 2}, {"sessions": 3, "last_session_operation": 1}), (1, 1))
        self.assertEqual(dragout.session(None, None), (0, None))


if __name__ == "__main__":
    unittest.main()
