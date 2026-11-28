#!/usr/bin/env python3
"""pair-e2e's exit evidence: a Mac app that ended before it answered is described in SUMMARY.md with
nothing the workflow's secret guard would drop the whole summary for (an address, JWT, bearer, token)."""
import json, os, re, sys, tempfile, types

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "../scripts/ci"))
import cmux_next_pair_e2e as p  # noqa: E402

GUARD = re.compile(r'sk-(ant-)?[A-Za-z0-9_-]{10,}|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}|bearer[[:space:]]+[A-Za-z0-9._~+/=-]+|refresh[_-]?token"?[[:space:]]*[:=]|password"?[[:space:]]*[:=]|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}'.replace("[[:space:]]", r"\s"), re.I)


def main():
    dirty = ["signed in as dev@example.com", "Authorization: Bearer abc.def", "t=SECRET123 pairToken: xyz",
             "jwt eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0.c2lnbmF0dXJlMTIz", 'refresh_token": "r-123', "password=hunter2",
             "key sk-ant-abcdefghijklmnop"]
    for line in dirty:
        clean = p.summary_safe(line)
        assert not GUARD.search(clean), (line, clean)
        assert "SECRET123" not in clean
    with tempfile.TemporaryDirectory() as out:
        with open(os.path.join(out, "mac-app.log"), "w") as f:
            f.write("".join(f"line {i}\n" for i in range(60)) + "Fatal error: dev@example.com\n")
        app = types.SimpleNamespace(poll=lambda: -6)
        text = p.exit_evidence(app, out)
        assert "signal 6 (SIGABRT)" in text, text
        assert "line 21" in text and "line 20\n" not in text, text
        assert "<address>" in text and not GUARD.search(text), text
        assert p.exit_evidence(types.SimpleNamespace(poll=lambda: None), out) == ""
        ips = os.path.join(out, "cmux.ips")
        with open(ips, "w") as f:
            f.write('{"app_name":"cmux"}\n' + json.dumps({
                "exception": {"type": "EXC_CRASH", "signal": "SIGABRT"}, "usedImages": [{"name": "cmux"}],
                "threads": [{"triggered": True, "frames": [{"imageIndex": 0, "symbol": "main"}]}]}))
        frames = p.crash_frames(ips)
        assert any("EXC_CRASH" in f for f in frames) and "cmux main" in frames, frames
    print("ok")


if __name__ == "__main__":
    main()
