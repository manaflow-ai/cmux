#!/usr/bin/env python3
"""check-pointer-coalesce.py (MQ-pointer-per-event closing check, p04-input-089): each case writes a small
Packages/macOS/CmuxNext/Sources tree to a temp dir and reads the script's verdict for every override.

  python3 scripts/cmux-next/tests/test_check_pointer_coalesce.py
"""
from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "check-pointer-coalesce.py"
SPEC = importlib.util.spec_from_file_location("check_pointer_coalesce", SCRIPT)
assert SPEC and SPEC.loader
check = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = check  # dataclasses read the module's namespace while the class is built
SPEC.loader.exec_module(check)


class CheckPointerCoalesceTests(unittest.TestCase):
    def scan(self, files: dict[str, str]) -> dict[tuple[str, str], str]:
        """`files` maps `Target/File.swift` to its text; the result maps (file name, method) to its verdict."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for rel, text in files.items():
                path = root / check.SOURCES / rel
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text, encoding="utf-8")
            return {(Path(h.path).name, h.name): h.verdict for h in check.scan(root)}

    def test_a_post_on_a_consumer_property_is_coalesced(self) -> None:
        verdicts = self.scan({"CmuxNextA/Drag.swift": """
final class Drag: NSView {
    private var frameDrag: PointerFrameConsumer?
    override func mouseDragged(with event: NSEvent) {
        if let frameDrag, frameDrag.post(event) { return }
        move(event)
    }
}
"""})
        self.assertEqual(verdicts[("Drag.swift", "mouseDragged")], "coalesced")

    def test_a_helper_or_a_property_in_another_file_of_the_target_counts(self) -> None:
        verdicts = self.scan({
            "CmuxNextA/Hover.swift": """
final class Hover: NSView {
    override func mouseMoved(with event: NSEvent) { route(event) }
}
""",
            "CmuxNextA/Hover+Frames.swift": """
extension Hover {
    func route(_ event: NSEvent) { hoverMoves.moved(event) }
}
final class HoverHolder {
    lazy var hoverMoves = PointerFrameHover(owner: "x", view: NSView()) { _ in }
}
""",
        })
        self.assertEqual(verdicts[("Hover.swift", "mouseMoved")], "coalesced")

    def test_a_local_bound_to_a_consumer_property_counts(self) -> None:
        verdicts = self.scan({
            "CmuxNextA/State.swift": "struct CanvasState { var dragFrames: PointerFrameConsumer? }\n",
            "CmuxNextA/Canvas.swift": """
final class Canvas: NSView {
    var state = CanvasState()
    override func mouseDragged(with event: NSEvent) {
        if let frames = state.dragFrames, frames.post(event) { return }
        move(event)
    }
    override func mouseMoved(with event: NSEvent) {
        let frames = state.dragFrames.map { $0 }
        frames?.post(event)
    }
}
""",
        })
        self.assertEqual(verdicts[("Canvas.swift", "mouseDragged")], "coalesced")
        self.assertEqual(verdicts[("Canvas.swift", "mouseMoved")], "", "a value made from it is not the consumer")

    def test_a_wrapper_type_that_holds_a_consumer_counts(self) -> None:
        verdicts = self.scan({"CmuxNextA/Term.swift": """
final class TermFrames {
    private var consumer: PointerFrameConsumer?
    func post(_ event: NSEvent, in window: NSWindow?) -> Bool { true }
}
final class Term: NSView {
    var pointerFrames: TermFrames?
    public override func mouseMoved(with event: NSEvent) {
        if pointerFrames?.post(event, in: window) == true { return }
    }
}
"""})
        self.assertEqual(verdicts[("Term.swift", "mouseMoved")], "coalesced")

    def test_a_drag_on_a_pointer_frame_drag_is_coalesced(self) -> None:
        verdicts = self.scan({"CmuxNextA/Row.swift": """
final class Row: NSView {
    private(set) lazy var dragMoves = PointerFrameDrag(owner: "Row.drag", view: self) { [weak self] point in self?.move(point) }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        if didDrag { return dragMoves.dragged(event) }
        didDrag = onDragged?(start, event.locationInWindow) == true
    }
}
"""})
        self.assertEqual(verdicts[("Row.swift", "mouseDragged")], "coalesced")

    def test_a_closure_forward_counts_when_every_closure_stored_in_it_posts(self) -> None:
        menu = """
final class Menu: NSView {
    private(set) lazy var hoverMoves = PointerFrameHover(owner: "Menu.hover", view: self) { _ in }
    func build(_ row: MenuRow) {
        row.onMove = { [weak self] event in self?.hoverMoves.moved(event) }
    }
}
final class MenuRow: NSView {
    var onMove: ((NSEvent) -> Void)?
    override func mouseMoved(with event: NSEvent) {
        onMove?(event)
    }
}
"""
        self.assertEqual(self.scan({"CmuxNextA/Menu.swift": menu})[("Menu.swift", "mouseMoved")], "coalesced")
        other = "final class Other { func wire(_ row: MenuRow) { row.onMove = { event in highlight(event) } } }\n"
        verdicts = self.scan({"CmuxNextA/Menu.swift": menu, "CmuxNextA/Other.swift": other})
        self.assertEqual(verdicts[("Menu.swift", "mouseMoved")], "", "one closure stored in it acts on every event")

    def test_a_native_note_needs_a_reason(self) -> None:
        verdicts = self.scan({"CmuxNextA/Page.swift": """
final class Page: WKWebView {
    // input-coalesce: native (WebKit coalesces its own moves)
    override func mouseDragged(with event: NSEvent) { super.mouseDragged(with: event) }
    // input-coalesce: native
    override func mouseMoved(with event: NSEvent) { super.mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { super.rightMouseDragged(with: event) } // input-coalesce: native (the same)
}
"""})
        self.assertEqual(verdicts[("Page.swift", "mouseDragged")], "native")
        self.assertEqual(verdicts[("Page.swift", "mouseMoved")], "", "a bare note does not pass")
        self.assertEqual(verdicts[("Page.swift", "rightMouseDragged")], "native")

    def test_a_note_above_a_doc_comment_and_other_markers_still_counts(self) -> None:
        verdicts = self.scan({"CmuxNextA/Chip.swift": """
final class Chip: NSView {
    /// Drags the page out.
    // input-coalesce: native (an AppKit dragging session tracks the pointer)
    // local-monitor-allow: the session starts from this event
    override func mouseDragged(with event: NSEvent) { beginDraggingSession(with: [], event: event, source: self) }
}
"""})
        self.assertEqual(verdicts[("Chip.swift", "mouseDragged")], "native")

    def test_an_empty_body_passes_and_per_event_work_does_not(self) -> None:
        verdicts = self.scan({"CmuxNextA/Views.swift": """
final class Swallow: NSView {
    override public func mouseDragged(with event: NSEvent) {}
}
final class Pet: NSView {
    override func otherMouseDragged(with event: NSEvent) {
        window?.setFrameOrigin(event.locationInWindow) // "frameDrag.post(" in a comment does not count
        let text = "frameDrag.post(event)"
    }
}
"""})
        self.assertEqual(verdicts[("Views.swift", "mouseDragged")], "empty")
        self.assertEqual(verdicts[("Views.swift", "otherMouseDragged")], "")

    def test_doc_examples_are_not_overrides(self) -> None:
        verdicts = self.scan({"CmuxNextA/Docs.swift": """
/// ```swift
/// override func mouseDragged(with event: NSEvent) { drag.post(event) }
/// ```
final class Docs {}
"""})
        self.assertEqual(verdicts, {})

    def test_another_targets_consumer_property_does_not_count(self) -> None:
        verdicts = self.scan({
            "CmuxNextA/Owner.swift": "final class Owner { var frameDrag: PointerFrameConsumer? }\n",
            "CmuxNextB/Other.swift": """
final class Other: NSView {
    override func mouseDragged(with event: NSEvent) { frameDrag.post(event) }
}
""",
        })
        self.assertEqual(verdicts[("Other.swift", "mouseDragged")], "")

    def test_main_exits_nonzero_with_open_hits_and_zero_without(self) -> None:
        for text, code in (("override func mouseMoved(with event: NSEvent) { hover(event) }", 1),
                           ("override func mouseMoved(with event: NSEvent) { hover.coalescer(for: window!) }", 0)):
            with tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / check.SOURCES / "CmuxNextA" / "V.swift"
                path.parent.mkdir(parents=True)
                path.write_text("final class V: NSView {\n    " + text + "\n}\n", encoding="utf-8")
                with self.subTest(code=code):
                    self.assertEqual(check.main(["--root", tmp]), code)


if __name__ == "__main__":
    unittest.main()
