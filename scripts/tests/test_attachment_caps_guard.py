import importlib.util
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "cmux-next" / "check-attachment-caps.py"
SPEC = importlib.util.spec_from_file_location("attachment_caps_guard", SCRIPT)
assert SPEC and SPEC.loader
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)


def test_tree_has_no_user_attachment_cap_names() -> None:
    assert guard.violations(SCRIPT.parents[2]) == []


def test_rejects_a_new_max_bytes_cap(tmp_path: Path) -> None:
    source = tmp_path / "webviews/src/uploads/service.ts"
    source.parent.mkdir()
    source.write_text("let MAX_ATTACHMENT_BYTES = 100\n", encoding="utf-8")
    assert guard.violations(tmp_path) == ["webviews/src/uploads/service.ts:1: MAX_ATTACHMENT_BYTES"]

