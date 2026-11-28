#!/usr/bin/env python3
"""The `cmux/ui-proof` commit status: a pull request that changes what a desktop user sees (the Mac app, cmux NEXT's
GUI, its webviews) lands only with a proof record at its current head, a look at the change running in a copy of
NIGHTLY with its screens diffed against NIGHTLY's (scripts/cmux-next/hot-verify.py look --record).

Leo, 2026-11-27: "obviously for visuals we'll need to do better before getting them in but you know". On new
visible UI: "it can potentially just not ship until we get a proper handle and shell of it and/or build". On why
the loops were skipped: "we prev didn't really have good enough fast enough stuff so i just bypassed a bunch of
stuff / but now we have 10 more m5 pro mac minis and etc".

Why a gate (the data, cmuxterm-hq docs/findings/ui-regressions.md): 25 desktop UI pull requests merged into
feat-cmux-next from 2026-10-16 to 11-27 were reverted or fixed forward, median 0 days from merge; 10 of them were
never seen running before merge (no shot, no video, "Not run" in the body), 8 put new visible UI or a default on
that nobody asked for, 5 landed half of a feature. Every one of the 25 touched a path this gate calls visual, and
none carried a look at its head (tests/test_ci_ui_proof_verdict.py RevertedHistoryTest holds the list).

The state, for a head:

  success  the head changes nothing a user sees: docs, copy (strings catalogs), tests, scripts, CI, Rust that
           renders nothing, iOS (cmux/ios-fast has it). Posted by the router at once, so a ruleset can require it
  success  the body says `Visual: none (WHY)`: a refactor or logging change under a visual path with no output
           change. Counted as a bypass by `report`
  pending  visual, and no passing record of an accepted suite at this head whose screens were diffed against
           NIGHTLY's (`visual.diffed`). A new push needs a new look
  pending  the head adds new visible UI (a new view or component file) and the body does not say
           `Visible-UI: complete`, or the record has fewer than 3 captures (3 gallery variants). Until then it
           stays on its branch: `cmux app try N` puts it in NIGHTLY, `cmux customize use pr:N` loads its web half,
           scripts/cmux-next/try-pr.sh N runs it beside
  failure  the record at this head failed
  failure  the look could not run (`UI look could not run: REASON`): the fleet cancelled it (no Mac took it within
           the controller's 3 h queue bound), lost its out.tar, its worker planned a build, or no look result came
           within STALE_HOURS of the pending post (`sweep`). Never an endless pending: on 2026-11-27 cmux#61289,
           #61543 and #61546 sat pending 4 h+ while their looks were cancelled twice ("no fleet Mac took the look
           within 3h0m0s") and nothing said so. Leo, 2026-11-27: "we need to be fixing reds as they come instead of
           just waving them off". A later passing record still turns it to success (the gate is rerun)

Accepted suites (ci/proof-record/README.md): a webviews-only change takes web-flows, gui-flows or mac-flows; a
change to the app's Swift, resources or assets takes gui-flows or mac-flows (a Linux web gallery never ran the
Swift). Switch: vars.CI_UI_PROOF=0 posts success everywhere (counted by `report` too).

    ui_proof_verdict.py affects FILE...           whether these paths are visual, and which suites prove them
    ui_proof_verdict.py gate                      env REPO PR SHA GH_TOKEN [ADDED_FILE]: print STATE<TAB>DESC
    ui_proof_verdict.py status STATE DESCRIPTION  env REPO SHA TOKENS [RUN_URL]: post cmux/ui-proof (never fails)
    ui_proof_verdict.py look-failed --pr N --reason R [--again]
                                                  env REPO SHA TOKENS [RUN_URL]: post the failure of a look that
                                                  could not run (the hot-verify result run)
    ui_proof_verdict.py sweep [--hours 6]         env REPO TOKENS: every open PR whose cmux/ui-proof has been
                                                  pending past HOURS gets the failure, with that reason
    ui_proof_verdict.py record --out DIR --pr N --repo R --head SHA [--suite S] [--post]
                                                  the proof record of a hot-verify look's DIR
    ui_proof_verdict.py report [--days 7]         env REPO GH_TOKEN: merged PRs, how each passed this gate, and
                                                  every bypass with its reason (the weekly count)

Stdlib only.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import hashlib
import json
import os
import re
import struct
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import proof_record  # noqa: E402

STATUS_CONTEXT = "cmux/ui-proof"
GATE_JOB = "ui proof status"
MIN_GALLERY = 3

# What a desktop user sees. iOS (cmux-next-ios, Packages/iOS) is cmux/ios-fast's.
WEB_VISUAL = ("webviews/src/", "webviews/index.html", "webviews/*-page.html")
APP_VISUAL = ("Packages/macOS/", "Packages/Shared/", "Native/", "Resources/", "Assets.xcassets/", "AppIcon.icon/",
              "App/")
# Under a visual root, still nothing a user sees: tests, fixtures, benches, docs, copy (Leo's tier 0 keeps copy fast).
NOT_VISUAL = ("*/Tests/*", "*Tests.swift", "*/test/*", "*/tests/*", "*/__tests__/*", "*.test.*", "*.spec.*",
              "*/bench/*", "*.bench.*", "*/fixtures/*", "*.md", "*.xcstrings", "*.strings", "*/dev-server/*",
              "Resources/Info.plist", "*.entitlements", "Packages/macOS/CmuxNext/app-ffi-pin.json")
# app-ffi-pin.json is the release bot's FFI pin roll (app-ffi-release.yml): its Rust already merged in the PRs that
# changed it (Rust is not visual here; hot-verify looks at it on that PR), and no look can run on the roll itself
# (hot-verify needs a build for an xcframework), so the bot's pin PR stayed pending: cmux#60965 from 14:56Z 11-27,
# the FFI pin 600 min behind main. The pin PR's Package.swift imports only PackageDescription.
# A Swift file whose every import is one of these has no way to draw (no SwiftUI, AppKit, CoreGraphics, Metal, WebKit,
# GhosttyKit or a Cmux module that might re-export them), so changing it changes no pixels. A file with no import at
# all, an unread one, or one that dropped a UI import (its base text is checked too) stays visual.
NON_UI_IMPORTS = frozenset({"Foundation", "Combine", "os", "OSLog", "Darwin", "Dispatch", "Observation", "CryptoKit",
                            "Security", "Network", "XCTest", "Testing", "PackageDescription", "Synchronization",
                            "System", "UniformTypeIdentifiers", "SwiftData", "RegexBuilder", "Accelerate"})
SWIFT_IMPORT = re.compile(r"^[ \t]*(?:@\w+(?:\([^)]*\))?[ \t]+)*import[ \t]+(?:\w+[ \t]+)?(?P<mod>[A-Za-z_]\w*)",
                          re.M)
NEW_UI_EXT = (".tsx", ".css", ".swift")
SWIFT_VIEW = re.compile(r":\s*(?:some\s+)?(?:View|NSView|NSViewController|NSWindowController|NSPanel)\b|"
                        r"\bvar body:\s*some View\b")
DECLARED_NONE = re.compile(r"^\s*Visual:\s*none\b[\s:(—-]*(?P<why>.*)$", re.M | re.I)
DECLARED_COMPLETE = re.compile(r"^\s*Visible-UI:\s*complete\b", re.M | re.I)
DECLARED_NOT_NEW = re.compile(r"^\s*Visible-UI:\s*none\b", re.M | re.I)
PREVIEW = "preview: cmux app try {pr} | cmux customize use pr:{pr} | try-pr.sh {pr}"
# A look that could not run is a failure with its reason, never a pending that waits for ever.
LOOK_FAILED = "UI look could not run"
NO_LOOK = "Visual change, no look at this head"
LOOK_WAIT = "Visual change, "
# The longest a look can take and still answer: two looks (the first, and one more when it returns no out.tar), each
# bounded by the controller (cmuxterm-hq build-fleet/cmd/controller/hot_verify_look.go: submit 30 min, queue 3 h,
# run 45 min). A pending older than this has no look coming: the controller never saw the request or never reported.
STALE_HOURS = 6


def _match(path: str, patterns) -> bool:
    return any(path.startswith(p) if p.endswith("/") else fnmatch.fnmatchcase(path, p) for p in patterns)


def kind(path: str) -> str:
    """'web', 'app' or '' (nothing a desktop user sees)."""
    if _match(path, NOT_VISUAL):
        return ""
    if _match(path, WEB_VISUAL):
        return "web"
    if _match(path, APP_VISUAL):
        return "app"
    return ""


def swift_draws(texts) -> bool:
    """Whether Swift TEXTS (a file's head and base text) can change pixels: no import, or any import outside
    NON_UI_IMPORTS."""
    for text in texts:
        mods = {m.group("mod") for m in SWIFT_IMPORT.finditer(re.sub(r"/\*.*?\*/", "", text, flags=re.S))}
        if not mods or not mods <= NON_UI_IMPORTS:
            return True
    return False


def affects(paths, read=None) -> str:
    """'' when PATHS change nothing a user sees; 'web' when only webviews; 'app' when any Swift that can draw, resource
    or asset. READ(path) gives a Swift file's texts (head and base, whichever exist) or raises OSError (unread = draws);
    without READ every Swift file under a visual root counts."""
    kinds = set()
    for p in paths:
        k = kind(p)
        if k == "app" and read is not None and p.endswith(".swift"):
            try:
                if not swift_draws(read(p)):
                    continue
            except OSError:
                pass
        kinds.add(k)
    kinds -= {""}
    return "app" if "app" in kinds else ("web" if kinds else "")


def suites_for(need: str) -> tuple[str, ...]:
    return {"web": ("web-flows", "gui-flows", "mac-flows"), "app": ("gui-flows", "mac-flows")}.get(need, ())


def new_ui(added: list[str], read=None) -> list[str]:
    """The ADDED paths that are new visible UI: a new component or stylesheet under webviews/src, or a new Swift file
    under a visual root that declares a view (READ(path) gives its text; unread Swift counts)."""
    out = []
    for path in added:
        if kind(path) == "" or not path.endswith(NEW_UI_EXT):
            continue
        if path.endswith(".swift"):
            text = None
            if read is not None:
                try:
                    text = read(path)
                except OSError:
                    text = None
            if text is not None and not SWIFT_VIEW.search(text):
                continue
        out.append(path)
    return out


def verdict(need: str, body: str, records: dict[str, dict | None], added_ui: list[str], pr: str | int = "N",
            off: bool = False) -> tuple[str, str]:
    """The (state, description) for a head. RECORDS: suite -> the newest trusted record at the head (proof_record.find)."""
    if off:
        return "success", "UI proof is off (vars.CI_UI_PROOF=0)"
    if not need:
        return "success", "Touches nothing a user sees (docs, copy, tests, CI, iOS has cmux/ios-fast)"
    m = DECLARED_NONE.search(body or "")
    if m:
        why = m.group("why").strip(" )") or "no reason given"
        return "success", f"Declared no visual change: {why}"[:140]
    preview = PREVIEW.format(pr=pr)
    got = [r for s in suites_for(need) if (r := records.get(s))]
    passing = [r for r in got if r.get("verdict") == "pass"]
    if got and not passing:
        failed = [x["name"] for x in got[0].get("runs", []) if x.get("result") in ("fail", "error")]
        return "failure", f"UI proof at this head failed: {', '.join(failed) or 'see the record'}"[:140]
    diffed = [r for r in passing if (r.get("visual") or {}).get("diffed")]
    if not diffed:
        what = "no screens diffed against NIGHTLY" if passing else "no look at this head"
        return "pending", f"Visual change, {what}: hot-verify.py look --pr {pr} --record; {preview}"[:140]
    best = max(diffed, key=lambda r: len(r.get("captures") or []))
    if added_ui and not DECLARED_NOT_NEW.search(body or ""):
        if not DECLARED_COMPLETE.search(body or ""):
            return "pending", (f"New visible UI ({len(added_ui)} files) ships whole or stays on its branch; "
                               f"say Visible-UI: complete. {preview}")[:140]
        if len(best.get("captures") or []) < MIN_GALLERY:
            return "pending", f"New visible UI needs {MIN_GALLERY}+ gallery captures at this head; {preview}"[:140]
    v = best.get("visual") or {}
    took = (best.get("timing") or {}).get("push_to_proof_s")
    return "success", (f"{best['suite']} at this head: {v.get('screens', 0)} screens, {v.get('changed', 0)} changed "
                       f"vs NIGHTLY" + (f", {int(took)}s push to proof" if took else ""))[:140]


# --- PNG pixel diff (8-bit RGB or RGBA, not interlaced: what screencapture writes) --------------------------------

def png_rgba(data: bytes) -> tuple[int, int, int, bytes] | None:
    """(width, height, channels, raw rows unfiltered) or None for a PNG this reader does not decode."""
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        return None
    at, idat, ihdr = 8, [], None
    while at + 8 <= len(data):
        size = int.from_bytes(data[at:at + 4], "big")
        tag = data[at + 4:at + 8]
        chunk = data[at + 8:at + 8 + size]
        if tag == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", chunk)
        elif tag == b"IDAT":
            idat.append(chunk)
        at += 12 + size
    if not ihdr:
        return None
    w, h, depth, color, _, _, interlace = ihdr
    channels = {2: 3, 6: 4}.get(color)
    if depth != 8 or channels is None or interlace:
        return None
    raw = zlib.decompress(b"".join(idat))
    stride = w * channels
    out = bytearray(h * stride)
    prev = bytearray(stride)
    pos = 0
    for y in range(h):
        f = raw[pos]
        line = bytearray(raw[pos + 1:pos + 1 + stride])
        pos += 1 + stride
        if f == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 255
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 255
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return w, h, channels, bytes(out)


def diff_ratio(before: bytes, after: bytes, tolerance: int = 8) -> float | None:
    """The share of pixels whose colour moved past TOLERANCE in any channel (1.0 when the sizes differ); None when
    either is a PNG this reader does not decode (the capture is then compared by its digest only)."""
    a, b = png_rgba(before), png_rgba(after)
    if a is None or b is None:
        return None
    if a[:2] != b[:2]:
        return 1.0
    w, h = a[0], a[1]
    ca, cb, pa, pb = a[2], b[2], a[3], b[3]
    changed = 0
    for i in range(w * h):
        x, y = pa[i * ca:i * ca + 3], pb[i * cb:i * cb + 3]
        if x != y and max(abs(x[0] - y[0]), abs(x[1] - y[1]), abs(x[2] - y[2])) > tolerance:
            changed += 1
    return round(changed / (w * h), 6) if w * h else 0.0


# --- the record of a hot-verify look -------------------------------------------------------------------------------

def suite_of(plan: dict | None) -> str:
    """gui-flows when the look put Rust in (NEXT's daemon and GUI), web-flows for a web-only layer, else mac-flows. A
    look that built the head app for its Swift (plan "build") shot that app: mac-flows, though its hot-swap layers
    read ["web"]; as web-flows a Swift change's gate, which reads only gui-flows and mac-flows, never saw it (#61705)."""
    layers = (plan or {}).get("layers") or []
    if "rust" in layers:
        return "gui-flows"
    if (plan or {}).get("build"):
        return "mac-flows"
    return "web-flows" if layers == ["web"] else "mac-flows"


def build_record(out: Path, *, repo: str, pr: int, head: str, suite: str | None = None, base_sha: str = "",
                 pushed_at: float | None = None, now: float | None = None) -> dict:
    """The proof record of hot-verify.py look's --out DIR (receipt.json, before/, after/, steps/, video.mp4). Any
    capture that writes the same layout counts: a Swift change, which the look cannot hot-swap, shoots NIGHTLY into
    before/ and the PR's build into after/ (no receipt.json then: pass --suite mac-flows)."""
    path = out / "receipt.json"
    receipt = json.loads(path.read_text()) if path.is_file() else {}
    plan = receipt.get("plan") or {}
    captures, baselined, changed = [], 0, 0
    shots = sorted((out / "after").glob("*.png")) + sorted((out / "steps").glob("*.png"))
    for shot in shots:
        data = shot.read_bytes()
        name = f"{shot.parent.name}/{shot.name}"
        before = out / "before" / shot.name if shot.parent.name == "after" else None
        cap = {"name": name, "sha256": hashlib.sha256(data).hexdigest(), "verdict": "unbaselined", "diff_ratio": None}
        if before is not None and before.is_file():
            baselined += 1
            ratio = diff_ratio(before.read_bytes(), data)
            same = (ratio == 0.0) if ratio is not None else (before.read_bytes() == data)
            cap["diff_ratio"] = ratio
            cap["verdict"] = "same" if same else "changed"
            changed += 0 if same else 1
        elif before is not None:
            cap["verdict"] = "new"
        captures.append(cap)
    errors = receipt.get("errors") or []
    looked = bool(shots) and (out / "after" / "light.png").is_file() and not errors
    runs = [{"name": "look", "result": "pass" if looked else "fail", "mode": ",".join(plan.get("layers") or []),
             "seconds": (receipt.get("phases") or {}).get("total"),
             **({"note": "; ".join(errors)[:300]} if errors else {})}]
    for step in receipt.get("steps") or []:
        if isinstance(step, dict) and step.get("name"):
            ok = step.get("ok", not step.get("error"))
            runs.append({"name": f"step {step['name']}", "result": "pass" if ok else "fail",
                         **({"note": str(step.get("error"))[:200]} if step.get("error") else {})})
    video = (out / "video.mp4").is_file()
    now = time.time() if now is None else now
    timing = {"proof_at": dt.datetime.fromtimestamp(now, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
    if pushed_at:
        timing["pushed_at"] = dt.datetime.fromtimestamp(pushed_at, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        timing["push_to_proof_s"] = round(now - pushed_at, 1)
    record = {
        "kind": proof_record.KIND, "version": proof_record.VERSION, "suite": suite or suite_of(plan), "repo": repo,
        "pr": int(pr), "head_sha": head, "base_sha": base_sha or plan.get("base") or "", "merged_base": False,
        "selection": {"flows": [c["name"] for c in captures], "layers": plan.get("layers") or []},
        "runs": runs, "captures": captures,
        "baseline": {"source": "nightly", "sha": (receipt.get("app") or {}).get("commit") or "",
                     "version": (receipt.get("app") or {}).get("version") or ""},
        "visual": {"screens": len(captures), "baselined": baselined, "changed": changed, "video": video,
                   "diffed": baselined > 0},
        "video": "video.mp4" if video else None,
        "verdict": "pass" if all(r["result"] == "pass" for r in runs) else "fail",
        "timing": timing, "tool": "scripts/cmux-next/hot-verify.py look --record",
    }
    bad = proof_record.problems(record)
    if bad:
        raise ValueError("; ".join(bad))
    return record


def summary(record: dict) -> str:
    v = record["visual"]
    rows = "\n".join(f"| `{c['name']}` | {c['verdict']} | {'' if c.get('diff_ratio') is None else c['diff_ratio']} |"
                     for c in record["captures"])
    return (f"**UI proof** ({record['suite']}) at `{record['head_sha'][:12]}`: {record['verdict']}, "
            f"{v['screens']} screens, {v['baselined']} diffed against NIGHTLY "
            f"{(record.get('baseline') or {}).get('sha', '')[:12]}, {v['changed']} changed"
            f"{', video' if v['video'] else ''}.\n\n| capture | vs NIGHTLY | pixels changed |\n|---|---|---|\n{rows}")


# --- GitHub ---------------------------------------------------------------------------------------------------------

def api(path: str, token: str, method: str = "GET", body: dict | None = None):
    req = urllib.request.Request(f"https://api.github.com/{path.lstrip('/')}", method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Accept": "application/vnd.github+json", "Authorization": f"Bearer {token}",
                                          "X-GitHub-Api-Version": "2022-11-28"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read() or b"null")


def post_status(state: str, description: str, repo: str, sha: str, tokens: list[str], target_url: str = "") -> bool:
    body = {"state": state, "context": STATUS_CONTEXT, "description": description[:140],
            **({"target_url": target_url} if target_url else {})}
    for attempt in range(3):
        for token in tokens:
            try:
                api(f"repos/{repo}/statuses/{sha}", token, "POST", body)
                return True
            except Exception as e:  # noqa: BLE001 - the next token, then the next round
                print(f"{STATUS_CONTEXT}: post refused ({type(e).__name__}: {e})", file=sys.stderr)
        time.sleep(5 * (attempt + 1))
    return False


def added_files() -> list[str]:
    """The paths the merge commit adds against its first parent (the base tip); [] when unread."""
    try:
        out = subprocess.run(["git", "diff", "--name-only", "--no-renames", "--diff-filter=A", "-z", "HEAD^1", "HEAD"],
                             check=True, capture_output=True, text=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return []
    return [p for p in out.split("\0") if p]


def changed_files() -> list[str] | None:
    try:
        out = subprocess.run(["git", "diff", "--name-only", "--no-renames", "-z", "HEAD^1", "HEAD"],
                             check=True, capture_output=True, text=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    return [p for p in out.split("\0") if p]


def show(path: str) -> str:
    """PATH's text at HEAD (a sparse checkout has not got it on disk; the blob filter fetches it)."""
    try:
        return subprocess.run(["git", "show", f"HEAD:{path}"], check=True, capture_output=True, text=True,
                              errors="replace", timeout=60).stdout
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        raise OSError(str(e)) from e


def show_both(path: str) -> list[str]:
    """PATH's texts at HEAD and at its first parent, whichever exist; OSError when neither is readable."""
    out = []
    for rev in ("HEAD", "HEAD^1"):
        try:
            out.append(subprocess.run(["git", "show", f"{rev}:{path}"], check=True, capture_output=True, text=True,
                                      errors="replace", timeout=60).stdout)
        except subprocess.CalledProcessError:
            continue  # absent at that rev: added or deleted
        except subprocess.TimeoutExpired as e:
            raise OSError(str(e)) from e
    if not out:
        raise OSError(path)
    return out


def look_failed(reason: str, pr: str | int = "N", again: bool = False) -> tuple[str, str]:
    """The (state, description) of a look that could not run: failure, with its reason and the next step."""
    why = " ".join((reason or "no reason given").split())
    then = "one more look is queued" if again else f"hot-verify.py look --pr {pr} --record"
    return "failure", f"{LOOK_FAILED}: {why}; {then}"[:140]


def look_reason(env) -> str:
    """Why a result run made no record, from the publish job's step outputs (env names as in the workflow)."""
    reason = " ".join(env.get("REASON", "").split())
    if env.get("RESULT_OUTCOME") == "failure":
        return "the look's result was not read"
    if env.get("TAR") == "false":
        return reason or "the fleet sent no result"
    if env.get("NEEDS_BUILD") == "true":
        return "the look needs a build of this head first"
    if env.get("NOTHING") == "true":
        return "the look drew nothing"
    if env.get("NO_RECEIPT") == "true":
        return "the look's pictures came without a receipt"
    if env.get("STAGE_OUTCOME") == "failure":
        return "the look's pictures were not unpacked"
    return reason or "the look made no record"


def kept_look_failure(status: dict | None) -> tuple[str, str] | None:
    """A look failure already posted at this head (STATUS: the combined status' cmux/ui-proof entry), which a gate
    rerun with no record keeps: a body edit must not turn it back into a pending nothing will answer."""
    if status and status.get("state") == "failure" and (status.get("description") or "").startswith(LOOK_FAILED):
        return "failure", status["description"]
    return None


def current_status(repo: str, sha: str, token: str) -> dict | None:
    got = api(f"repos/{repo}/commits/{sha}/status?per_page=100", token) or {}
    return next((s for s in got.get("statuses") or [] if s.get("context") == STATUS_CONTEXT), None)


def stale_pending(prs: list[dict], now: dt.datetime, hours: float = STALE_HOURS) -> list[dict]:
    """The open PRs (PRS: graphql nodes, number, headRefOid, the head's cmux/ui-proof context) whose cmux/ui-proof
    has been pending longer than HOURS."""
    out = []
    for pr in prs:
        ctx = (((pr.get("commits") or {}).get("nodes") or [{}])[0].get("commit") or {}).get("status") or {}
        ctx = ctx.get("context") or {}
        # Only a pending that waits on a look ("Visual change, ..."); "say Visible-UI: complete" waits on the author.
        if ctx.get("state") != "PENDING" or not ctx.get("createdAt") or not str(ctx.get("description") or "").startswith(LOOK_WAIT):
            continue
        at = dt.datetime.fromisoformat(ctx["createdAt"].replace("Z", "+00:00"))
        if now - at > dt.timedelta(hours=hours):
            out.append({"pr": pr["number"], "sha": pr["headRefOid"], "since": ctx["createdAt"],
                        "description": ctx.get("description") or ""})
    return out


SWEEP_QUERY = """query($owner: String!, $name: String!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(states: OPEN, baseRefName: "feat-cmux-next", first: 100, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes { number headRefOid
        commits(last: 1) { nodes { commit { status { context(name: "cmux/ui-proof") {
          state description createdAt } } } } } }
    }
  }
}"""


def open_prs(repo: str, token: str) -> list[dict]:
    owner, name = repo.split("/", 1)
    nodes, after = [], None
    for _ in range(10):
        got = api("graphql", token, "POST", {"query": SWEEP_QUERY,
                                             "variables": {"owner": owner, "name": name, "after": after}})
        if got.get("errors"):
            raise RuntimeError(f"graphql: {got['errors'][0].get('message')}")
        page = got["data"]["repository"]["pullRequests"]
        nodes += page["nodes"]
        if not page["pageInfo"]["hasNextPage"]:
            break
        after = page["pageInfo"]["endCursor"]
    return nodes


def sweep(repo: str, tokens: list[str], hours: float, now: dt.datetime | None = None, post=None) -> list[dict]:
    """Post the look failure on every open PR whose cmux/ui-proof has been pending past HOURS."""
    post = post or post_status
    prs = proof_record.with_tokens(lambda token: open_prs(repo, token), tokens)
    stale = stale_pending(prs, now or dt.datetime.now(dt.timezone.utc), hours)
    for s in stale:
        state, desc = look_failed(f"no look result within {hours:g} h of the pending post", s["pr"])
        s["posted"] = post(state, desc, repo, s["sha"], tokens, os.environ.get("RUN_URL", ""))
    return stale


def gate_now(repo: str, pr: str, sha: str, token: str, bots: list[str]) -> tuple[str, str]:
    if os.environ.get("CI_UI_PROOF", "").strip() == "0":
        return verdict("", "", {}, [], pr, off=True)
    files = changed_files()
    need = "app" if files is None else affects(files, read=show_both)
    if not need:
        return verdict(need, "", {}, [], pr)
    body = (api(f"repos/{repo}/pulls/{pr}", token) or {}).get("body") or ""
    comments = proof_record.pr_comments(repo, pr, token)
    records = {s: proof_record.find(comments, s, sha, bots) for s in suites_for(need)}
    ui = new_ui(added_files(), read=show)
    state, desc = verdict(need, body, records, ui, pr)
    if state == "pending" and desc.startswith(NO_LOOK):
        try:
            kept = kept_look_failure(current_status(repo, sha, token))
        except Exception:  # noqa: BLE001 - an unread status keeps the pending; the sweep still bounds it
            kept = None
        return kept or (state, desc)
    return state, desc


def rerun_gate(repo: str, sha: str) -> str:
    """Rerun the PR's ui proof status job at SHA (gh, the brokered CLI on a fleet host) so it reads a new record."""
    def gh(*args):
        return json.loads(subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout or "null")
    try:
        runs = gh("api", f"repos/{repo}/actions/workflows/pr-router.yml/runs?head_sha={sha}&per_page=5")
        for run in (runs or {}).get("workflow_runs", []):
            for j in gh("api", f"repos/{repo}/actions/runs/{run['id']}/jobs?per_page=100").get("jobs", []):
                if j["name"] == GATE_JOB and j.get("status") == "completed" and j.get("conclusion") != "skipped":
                    subprocess.run(["gh", "run", "rerun", str(run["id"]), "--job", str(j["id"]), "--repo", repo],
                                   check=True, capture_output=True)
                    return f"reran {GATE_JOB} (job {j['id']})"
    except (OSError, subprocess.CalledProcessError, ValueError) as e:
        return f"gate not rerun: {e}"
    return "gate job has not run yet: it reads the record when it does"


# --- the weekly count of bypasses ----------------------------------------------------------------------------------

def classify_merge(status: dict | None, merged_by_override: bool = False) -> tuple[str, str]:
    """How a merged head passed this gate: (proved | untouched | declared | off | bypass, reason)."""
    if status is None:
        return "bypass", "no cmux/ui-proof status at the merged head"
    desc = status.get("description") or ""
    if status.get("state") != "success":
        return "bypass", f"merged at {status.get('state')}: {desc}"
    if desc.startswith("Touches nothing"):
        return "untouched", desc
    if desc.startswith("Declared"):
        return "declared", desc
    if desc.startswith("UI proof is off"):
        return "off", desc
    return "proved", desc


def report(repo: str, token: str, days: int, base: str = "feat-cmux-next") -> dict:
    since = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)).strftime("%Y-%m-%d")
    q = urllib.parse.quote(f"repo:{repo} is:pr is:merged base:{base} merged:>={since}")
    counts: dict[str, int] = {}
    bypasses = []
    for page in range(1, 11):
        got = api(f"search/issues?q={q}&per_page=100&page={page}", token).get("items", [])
        for item in got:
            pr = api(f"repos/{repo}/pulls/{item['number']}", token)
            sha = pr["head"]["sha"]
            statuses = api(f"repos/{repo}/commits/{sha}/statuses?per_page=100", token) or []
            mine = next((s for s in statuses if s.get("context") == STATUS_CONTEXT), None)
            how, why = classify_merge(mine)
            counts[how] = counts.get(how, 0) + 1
            if how in ("bypass", "declared", "off"):
                bypasses.append({"pr": item["number"], "how": how, "why": why, "title": item["title"][:80]})
        if len(got) < 100:
            break
    return {"since": since, "counts": counts, "bypasses": bypasses}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("affects")
    a.add_argument("paths", nargs="*")
    sub.add_parser("gate")
    lf = sub.add_parser("look-failed")
    lf.add_argument("--pr", required=True)
    lf.add_argument("--reason", default="")
    lf.add_argument("--again", action="store_true", help="one more look was started")
    sub.add_parser("look-reason")
    sw = sub.add_parser("sweep")
    sw.add_argument("--hours", type=float, default=STALE_HOURS)
    s = sub.add_parser("status")
    s.add_argument("state")
    s.add_argument("description")
    r = sub.add_parser("record")
    r.add_argument("--out", required=True)
    r.add_argument("--pr", required=True, type=int)
    r.add_argument("--repo", default="manaflow-ai/cmux")
    r.add_argument("--head", required=True)
    r.add_argument("--suite", choices=proof_record.SUITES)
    r.add_argument("--pushed-at", type=float)
    r.add_argument("--post", action="store_true", help="gh pr comment the record, then rerun the gate job")
    w = sub.add_parser("report")
    w.add_argument("--days", type=int, default=7)
    w.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    if args.cmd == "affects":
        need = affects(args.paths)
        print(json.dumps({"need": need, "suites": list(suites_for(need)),
                          "visual": [p for p in args.paths if kind(p)]}))
        return 0
    if args.cmd == "status":
        tokens = [t for t in os.environ.get("TOKENS", "").split() if t]
        ok = post_status(args.state, args.description, os.environ.get("REPO", ""), os.environ.get("SHA", ""), tokens,
                         os.environ.get("RUN_URL", ""))
        print(f"{STATUS_CONTEXT}: {args.state}: {args.description}" + ("" if ok else " (NOT posted)"))
        return 0
    if args.cmd == "look-failed":
        state, desc = look_failed(args.reason, args.pr, args.again)
        tokens = [t for t in os.environ.get("TOKENS", "").split() if t]
        ok = post_status(state, desc, os.environ.get("REPO", ""), os.environ.get("SHA", ""), tokens,
                         os.environ.get("RUN_URL", ""))
        print(f"{STATUS_CONTEXT}: {state}: {desc}" + ("" if ok else " (NOT posted)"))
        return 0 if ok else 1
    if args.cmd == "look-reason":
        print(look_reason(os.environ))
        return 0
    if args.cmd == "sweep":
        tokens = proof_record.read_tokens()
        stale = sweep(os.environ.get("REPO", "manaflow-ai/cmux"), tokens, args.hours)
        for s in stale:
            print(f"#{s['pr']} {s['sha'][:12]} pending since {s['since']}: failure posted={s['posted']}")
        print(f"{STATUS_CONTEXT} sweep: {len(stale)} pending past {args.hours:g} h")
        return 0 if all(s["posted"] for s in stale) else 1
    if args.cmd == "gate":
        repo, pr, sha = os.environ.get("REPO", ""), os.environ.get("PR", ""), os.environ.get("SHA", "")
        tokens = proof_record.read_tokens()
        bots = [b for b in os.environ.get("PROOF_RECORD_BOTS", proof_record.DEFAULT_BOTS).split(",") if b]
        if not (repo and pr and sha and tokens):
            print("error\tUI proof not read: REPO, PR, SHA and GH_TOKEN are needed")
            return 0
        try:
            state, desc = proof_record.with_tokens(lambda token: gate_now(repo, pr, sha, token, bots), tokens)
        except Exception as e:  # noqa: BLE001 - unread is an error state, never a pass
            state, desc = "error", f"UI proof not read ({proof_record.read_error(e)}): see job log"
        print(f"{state}\t{desc}")
        return 0
    if args.cmd == "record":
        out = Path(args.out)
        record = build_record(out, repo=args.repo, pr=args.pr, head=args.head, suite=args.suite,
                              pushed_at=args.pushed_at)
        text = proof_record.render(record, summary(record))
        (out / "proof-record.md").write_text(text)
        print(text)
        if args.post:
            subprocess.run(["gh", "pr", "comment", str(args.pr), "--repo", args.repo, "--body-file",
                            str(out / "proof-record.md")], check=True)
            print(rerun_gate(args.repo, args.head), file=sys.stderr)
        return 0 if record["verdict"] == "pass" else 1
    if args.cmd == "report":
        got = report(os.environ.get("REPO", "manaflow-ai/cmux"), os.environ.get("GH_TOKEN", ""), args.days)
        if args.json:
            print(json.dumps(got, indent=1))
        else:
            print(f"cmux/ui-proof since {got['since']}: " + ", ".join(f"{k} {v}" for k, v in sorted(got["counts"].items())))
            for b in got["bypasses"]:
                print(f"  #{b['pr']} {b['how']}: {b['why']}  ({b['title']})")
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
