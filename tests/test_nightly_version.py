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
import subprocess
import threading
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "nightly_version.py"


def run(*args):
    assert SCRIPT.is_file(), f"{SCRIPT} is missing"
    env = {**os.environ, "CMUX_NIGHTLY_FEED_RETRY_DELAYS": "0,0,0"}
    return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True, env=env, timeout=120)


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


def test_next_base_comes_from_the_cmux_tui_workspace():
    # cmux-tui/Cargo.toml [workspace.package] is the one cmux-next version;
    # nightly.yml passes `next-base` to `marketing`. The shipped line is 1.0.0.
    result = run("next-base")
    assert result.returncode == 0, result.stderr
    base = result.stdout.strip()
    assert base == "1.0.0", base
    assert marketing("nightly-next", next_base=base).startswith("1.0.0-nightly.")


def test_next_base_refuses_a_workspace_without_a_version():
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, "cmux-tui"))
        with open(os.path.join(d, "cmux-tui", "Cargo.toml"), "w") as f:
            f.write('[package]\nversion = "0.0.0"\n\n[workspace.package]\nedition = "2024"\n')
        assert run("next-base", "--root", d).returncode != 0


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


def test_a_feed_above_the_build_is_superseded_only_with_superseded_ok():
    """Run 40825878411: build 4082587841101 after 4082702109901 had published."""
    with tempfile.TemporaryDirectory() as d:
        nxt = write(d, "next.xml", appcast("4082702109901"))
        classic = write(d, "classic.xml", appcast("3719500000001"))
        refused = run("check-build", "--already-published-ok", "--build", "4082587841101", "--feed", nxt, "--feed", classic)
        assert refused.returncode != 0
        quiet = run("check-build", "--already-published-ok", "--superseded-ok", "--build", "4082587841101",
                    "--feed", nxt, "--feed", classic)
        assert quiet.returncode == 0, quiet.stderr
        assert quiet.stdout.strip().splitlines()[-1] == "superseded=true", quiet.stdout
        assert "superseded by 4082702109901" in quiet.stdout
        newer = run("check-build", "--already-published-ok", "--superseded-ok", "--build", "4082800000001",
                    "--feed", nxt, "--feed", classic)
        assert newer.returncode == 0, newer.stderr
        assert newer.stdout.strip().splitlines()[-2:] == ["already_published=false", "superseded=false"], newer.stdout
        same = run("check-build", "--already-published-ok", "--superseded-ok", "--build", "4082702109901",
                   "--feed", nxt, "--feed", classic)
        assert same.stdout.strip().splitlines()[-2:] == ["already_published=true", "superseded=false"], same.stdout


def test_superseded_ok_never_hides_an_unreadable_feed():
    with tempfile.TemporaryDirectory() as d:
        nxt = write(d, "next.xml", appcast("4082702109901"))
        result = run("check-build", "--superseded-ok", "--build", "4082587841101",
                     "--feed", nxt, "--feed", str(Path(d) / "missing.xml"))
        assert result.returncode != 0
        assert "superseded=true" not in result.stdout


def test_a_feed_with_an_unbound_cmux_prefix_is_read():
    # The live cmux NEXT feed of 2026-11-01: a carried item's bare <cmux:sourceCommit>
    # with only sparkle: declared on <rss>, beside an item that binds cmux: inline.
    unbound = appcast("3717696535601", "3718773117601").replace(
        "<item><sparkle:version>3717696535601",
        "<item><cmux:sourceCommit>" + "b" * 40 + "</cmux:sourceCommit><sparkle:version>3717696535601").replace(
        "<item><sparkle:version>3718773117601",
        '<item><cmux:sourceCommit xmlns:cmux="https://cmux.com/xml-namespaces/cmux">' + "c" * 40
        + "</cmux:sourceCommit><sparkle:version>3718773117601")
    with tempfile.TemporaryDirectory() as d:
        feed = write(d, "next.xml", unbound)
        assert run("check-build", "--build", "3719000000001", "--feed", feed).returncode == 0
        refused = run("check-build", "--build", "3718000000001", "--feed", feed)
        assert refused.returncode == 1 and "unbound" not in refused.stderr, refused.stderr


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


def feed_server(body, drops, truncate=False):
    """A loopback feed server that fails the first `drops` requests in transit
    (closes the connection without a response, or with `truncate` sends half
    of a declared body), then serves `body`."""
    state = {"left": drops, "requests": 0}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            state["requests"] += 1
            data = body.encode()
            if state["left"] > 0:
                state["left"] -= 1
                self.close_connection = True
                if truncate:
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data[: len(data) // 2])
                    self.wfile.flush()
                self.connection.shutdown(2)
                return
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
        server.server_close()
    server, url, state = feed_server(appcast("3718900000001"), drops=10)
    try:
        result = run("check-build", "--build", "3719000000001", "--feed", url)
        assert result.returncode != 0
        assert state["requests"] == 4, state
        assert "cannot read feed" in result.stderr
    finally:
        server.shutdown()
        server.server_close()
    server, url, state = feed_server(appcast("3718900000001"), drops=1, truncate=True)
    try:
        result = run("check-build", "--build", "3719000000001", "--feed", url)
        assert result.returncode == 0, result.stderr
        assert state["requests"] == 2, state
    finally:
        server.shutdown()
        server.server_close()


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
