#!/usr/bin/env python3
"""Nightly version numbers per track (scripts/ci/nightly_version.py).

cmux-next (track nightly-next) starts its own version line at
NIGHTLY_NEXT_MARKETING_VERSION (1.0.0) while main's nightly and RC keep the
project version. The build number (CFBundleVersion, which Sparkle compares)
stays the run-derived number, and nightly.yml refuses a cmux-next build whose
number is not above every build on the cmux-next feed and on main's NIGHTLY
feed, so neither feed can ever offer a downgrade after a switch.
"""

import http.server
import os
import re
import subprocess
import threading
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "nightly_version.py"
WORKFLOW = ROOT / ".github" / "workflows" / "nightly.yml"


def run(*args):
    assert SCRIPT.is_file(), f"{SCRIPT} is missing"
    env = {**os.environ, "CMUX_NIGHTLY_FEED_RETRY_DELAYS": "0,0,0"}
    return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True, env=env)


def marketing(track, project="0.64.25", build="3718773117601", next_base="1.0.0"):
    result = run("marketing", "--track", track, "--project-version", project,
                 "--build", build, "--next-base", next_base)
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()


def appcast(*versions):
    items = "".join(
        f"<item><sparkle:version>{v}</sparkle:version><enclosure url='https://x/{v}.dmg' sparkle:version='{v}'/></item>"
        for v in versions
    )
    return ('<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
            f"<channel>{items}</channel></rss>")


def write(directory, name, text):
    path = Path(directory) / name
    path.write_text(text)
    return str(path)


def test_next_track_starts_at_1_0_0():
    assert marketing("nightly-next") == "1.0.0-nightly.3718773117601"


def test_next_base_comes_from_the_workflow():
    # The workflow's value is the input; the shipped version must start at 1.0.0.
    match = re.search(r"^  NIGHTLY_NEXT_MARKETING_VERSION: \"?([0-9.]+)\"?$", WORKFLOW.read_text(), re.MULTILINE)
    assert match, "nightly.yml must set NIGHTLY_NEXT_MARKETING_VERSION at workflow level"
    assert marketing("nightly-next", next_base=match.group(1)).startswith("1.0.0-nightly.")


def test_main_nightly_and_rc_keep_the_project_version():
    assert marketing("nightly") == "0.64.25-nightly.3718773117601"
    assert marketing("rc") == "0.64.25-rc.3718773117601"


def test_refuses_malformed_inputs():
    assert run("marketing", "--track", "nightly-next", "--project-version", "0.64.25",
               "--build", "12ab", "--next-base", "1.0.0").returncode != 0
    assert run("marketing", "--track", "nightly-next", "--project-version", "0.64.25",
               "--build", "3718773117601", "--next-base", "1.0").returncode != 0
    assert run("marketing", "--track", "other", "--project-version", "0.64.25",
               "--build", "3718773117601", "--next-base", "1.0.0").returncode != 0


def test_build_above_both_feeds_is_allowed():
    with tempfile.TemporaryDirectory() as d:
        nxt = write(d, "next.xml", appcast("3717696535601", "3718773117601"))
        classic = write(d, "classic.xml", appcast("3718900000001"))
        assert run("check-build", "--build", "3719000000001", "--feed", nxt, "--feed", classic).returncode == 0


def test_build_not_above_the_next_feed_is_refused():
    with tempfile.TemporaryDirectory() as d:
        nxt = write(d, "next.xml", appcast("3718773117601"))
        assert run("check-build", "--build", "3718773117601", "--feed", nxt).returncode != 0
        assert run("check-build", "--build", "3718132883801", "--feed", nxt).returncode != 0


def test_build_not_above_classic_nightly_is_refused():
    with tempfile.TemporaryDirectory() as d:
        nxt = write(d, "next.xml", appcast("3718773117601"))
        classic = write(d, "classic.xml", appcast("3719500000001"))
        result = run("check-build", "--build", "3719000000001", "--feed", nxt, "--feed", classic)
        assert result.returncode != 0
        assert "3719500000001" in result.stderr


def test_unreadable_feed_is_refused():
    with tempfile.TemporaryDirectory() as d:
        broken = write(d, "broken.xml", "<rss")
        assert run("check-build", "--build", "3719000000001", "--feed", broken).returncode != 0
        assert run("check-build", "--build", "3719000000001", "--feed", str(Path(d) / "missing.xml")).returncode != 0


def test_a_feed_that_does_not_exist_yet_is_skipped_only_when_optional():
    # cmux NEXT's first build publishes a feed that does not exist yet.
    with tempfile.TemporaryDirectory() as d:
        classic = write(d, "classic.xml", appcast("3718900000001"))
        missing = str(Path(d) / "next" / "appcast-arm64.xml")
        assert run("check-build", "--build", "3719000000001", "--feed", classic, "--feed-if-present", missing).returncode == 0
        assert run("check-build", "--build", "3719000000001", "--feed", classic, "--feed", missing).returncode != 0
        present = write(d, "present.xml", appcast("3719500000001"))
        assert run("check-build", "--build", "3719000000001", "--feed", classic, "--feed-if-present", present).returncode != 0
        broken = write(d, "broken.xml", "<rss")
        assert run("check-build", "--build", "3719000000001", "--feed", classic, "--feed-if-present", broken).returncode != 0


def feed_server(body, drops):
    """A loopback feed server that closes the first `drops` connections
    without a response (a transit failure), then serves `body`."""
    state = {"left": drops, "requests": 0}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            state["requests"] += 1
            if state["left"] > 0:
                state["left"] -= 1
                self.close_connection = True
                self.connection.shutdown(2)
                return
            data = body.encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_address[1]}/appcast.xml", state


def test_a_feed_read_that_fails_in_transit_is_tried_again():
    # Run 39296746784: one TLS handshake timeout on a required feed failed the build.
    server, url, state = feed_server(appcast("3718900000001"), drops=2)
    try:
        result = run("check-build", "--build", "3719000000001", "--feed", url)
        assert result.returncode == 0, result.stderr
        assert state["requests"] == 3, state
        assert "trying again" in result.stderr
    finally:
        server.shutdown()
    server, url, state = feed_server(appcast("3718900000001"), drops=10)
    try:
        result = run("check-build", "--build", "3719000000001", "--feed", url)
        assert result.returncode != 0
        assert state["requests"] == 4, state
        assert "cannot read feed" in result.stderr
    finally:
        server.shutdown()


def main():
    tests = [(name, fn) for name, fn in globals().items() if name.startswith("test_") and callable(fn)]
    failed = 0
    for name, fn in tests:
        try:
            fn()
            print(f"ok   {name}")
        except Exception as error:  # noqa: BLE001 - report every failure
            failed += 1
            print(f"FAIL {name}: {error!r}")
    print(f"{len(tests) - failed}/{len(tests)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
