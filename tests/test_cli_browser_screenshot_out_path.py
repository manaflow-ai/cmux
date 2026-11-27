#!/usr/bin/env python3
"""`browser screenshot --out` writes one file and never replaces a directory."""

import base64
import os
import subprocess
import tempfile
import threading
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli
from test_browser_profile_cli import (
    FakeCmuxHandler,
    SURFACE_ID,
    ThreadedUnixServer,
    cli_environment,
)

CAPTURED_BYTES = b"\x89PNG\r\n\x1a\ncaptured"


class ScreenshotState:
    def __init__(self):
        self.calls = []
        self.reply = {}

    def handle(self, method, params):
        self.calls.append(method)
        if method != "browser.screenshot":
            raise AssertionError(f"Unexpected request: {method}")
        return {"surface_id": SURFACE_ID, **self.reply}


def run_screenshot(cli, socket_path, cwd, out_arguments):
    return subprocess.run(
        [cli, "--socket", socket_path, "browser", SURFACE_ID, "screenshot", *out_arguments],
        capture_output=True,
        text=True,
        check=False,
        cwd=cwd,
        env=cli_environment(),
        timeout=5,
    )


def make_scratch(root, name):
    scratch = Path(root) / name
    (scratch / "sub").mkdir(parents=True)
    (scratch / "keep.txt").write_text("keep")
    (scratch / "sub" / "nested.txt").write_text("nested")
    return scratch.resolve()


def assert_scratch_intact(scratch):
    assert scratch.is_dir(), f"{scratch} is no longer a directory"
    assert (scratch / "keep.txt").read_text() == "keep"
    assert (scratch / "sub").is_dir(), "sub is no longer a directory"
    assert (scratch / "sub" / "nested.txt").read_text() == "nested"


def check_rejected_targets(cli, socket_path, state, root):
    scratch = make_scratch(root, "rejected")
    (scratch / "link-to-sub").symlink_to(scratch / "sub")
    app_file = Path(root) / "rejected-app-file.png"
    app_file.write_bytes(CAPTURED_BYTES)
    cases = [
        ("empty path", ["--out", ""], None),
        ("no path after the flag", ["--out"], None),
        ("empty path with equals", ["--out="], None),
        ("blank path", ["--out", "  "], None),
        ("existing directory", ["--out", str(scratch / "sub")], str(scratch / "sub")),
        ("existing directory with slash", ["--out", f"{scratch}/sub/"], f"{scratch}/sub/"),
        ("relative directory", ["--out", "sub"], "sub"),
        ("working directory", ["--out", "."], "."),
        ("symlink to a directory", ["--out", str(scratch / "link-to-sub")], str(scratch / "link-to-sub")),
        ("missing path with slash", ["--out", f"{scratch}/missing/"], f"{scratch}/missing/"),
        ("missing path with dot", ["--out", f"{scratch}/missing/."], f"{scratch}/missing/."),
        ("missing path with dot dot", ["--out", f"{scratch}/missing/.."], f"{scratch}/missing/.."),
    ]
    for label, arguments, named_path in cases:
        state.calls.clear()
        state.reply = {
            "path": str(app_file),
            "png_base64": base64.b64encode(CAPTURED_BYTES).decode(),
        }
        result = run_screenshot(cli, socket_path, scratch, arguments)
        assert_scratch_intact(scratch)
        assert result.returncode != 0, f"{label}: exited 0: {result.stdout}"
        assert not result.stdout.startswith("OK"), f"{label}: printed {result.stdout!r}"
        if named_path is not None:
            assert named_path in result.stderr, f"{label}: error omits the path: {result.stderr!r}"
        assert state.calls == [], f"{label}: captured before rejecting: {state.calls}"
        assert (scratch / "link-to-sub").is_symlink(), f"{label}: the symlink was replaced"
        assert not (scratch / "missing").exists(), f"{label}: wrote through a directory-shaped path"


def check_file_targets(cli, socket_path, state, root):
    scratch = make_scratch(root, "files")
    source = scratch / "app-temp.png"
    source.write_bytes(CAPTURED_BYTES)
    encoded = base64.b64encode(CAPTURED_BYTES).decode()

    for label, reply in [
        ("app file reply", {"path": str(source)}),
        ("base64 reply", {"png_base64": encoded}),
    ]:
        state.reply = reply

        new_file = scratch / f"new-{len(label)}.png"
        result = run_screenshot(cli, socket_path, scratch, ["--out", str(new_file)])
        assert result.returncode == 0, f"{label}: {result.stderr}"
        assert new_file.read_bytes() == CAPTURED_BYTES, f"{label}: wrong bytes in a new file"

        existing = scratch / f"existing-{len(label)}.png"
        existing.write_bytes(b"old")
        result = run_screenshot(cli, socket_path, scratch, ["--out", existing.name])
        assert result.returncode == 0, f"{label}: {result.stderr}"
        assert existing.read_bytes() == CAPTURED_BYTES, f"{label}: did not replace a file"

        nested = scratch / f"made-{len(label)}" / "shot.png"
        result = run_screenshot(cli, socket_path, scratch, ["--out", str(nested)])
        assert result.returncode == 0, f"{label}: {result.stderr}"
        assert nested.read_bytes() == CAPTURED_BYTES, f"{label}: did not create the parent"

    assert_scratch_intact(scratch)
    assert source.read_bytes() == CAPTURED_BYTES, "the app's own file changed"


def check_failed_copy_keeps_existing_file(cli, socket_path, state, root):
    scratch = make_scratch(root, "failed-copy")
    existing = scratch / "existing.png"
    existing.write_bytes(b"old")
    state.reply = {"path": str(scratch / "app-file-that-is-gone.png")}
    result = run_screenshot(cli, socket_path, scratch, ["--out", str(existing)])
    assert result.returncode != 0, f"exited 0 with nothing to copy: {result.stdout}"
    assert existing.read_bytes() == b"old", "a failed copy deleted the existing file"


def check_missing_app_file_uses_base64(cli, socket_path, state, root):
    scratch = make_scratch(root, "missing-app-file")
    new_file = scratch / "from-base64.png"
    state.reply = {
        "path": str(scratch / "app-file-that-is-gone.png"),
        "png_base64": base64.b64encode(CAPTURED_BYTES).decode(),
    }
    result = run_screenshot(cli, socket_path, scratch, ["--out", str(new_file)])
    assert result.returncode == 0, f"missing app file: {result.stderr}"
    assert new_file.read_bytes() == CAPTURED_BYTES, "missing app file did not fall back to png_base64"


def main():
    cli = resolve_cmux_cli()
    with tempfile.TemporaryDirectory(prefix="cmux-shot-out-", dir="/tmp") as temporary:
        socket_path = os.path.join(temporary, "cmux.sock")
        state = ScreenshotState()
        server = ThreadedUnixServer(socket_path, FakeCmuxHandler)
        server.state = state
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            check_rejected_targets(cli, socket_path, state, temporary)
            check_file_targets(cli, socket_path, state, temporary)
            check_failed_copy_keeps_existing_file(cli, socket_path, state, temporary)
            check_missing_app_file_uses_base64(cli, socket_path, state, temporary)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
    print("PASS: browser screenshot --out keeps directories and existing files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
