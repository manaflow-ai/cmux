#!/usr/bin/env python3
"""Generate the pane-protocol suite: wire vectors with verdicts that the Rust, TS and Swift runners all read.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 3D (suite pane-protocol) and task 213. Stdlib only,
Python 3.9+, safe under `python3 -I`. `oracle.py gen --suite pane-protocol` runs it with
`--out <corpus>/pane-protocol`.

Chrome reference (chromium/src): mojo/public/interfaces/bindings/tests/data/validation/ is one set of message
vectors, each with the result the bindings must give, read by the C++, JS and Java bindings
(mojo/public/cpp/bindings/tests/validation_unittest.cc, mojo/public/js/test/validation_unittest.js). Here the
vectors are four files, one per category, and each implementation has one runner:

- Rust: `cargo run -p cmux-pane-protocol --example conformance` (cmux-tui/crates/cmux-pane-protocol/examples/).
- TS: `bun scripts/pane-protocol-conformance.ts` in webviews/.
- Swift: `PaneProtocolConformanceTests` in CmuxNextPagesTests (fleet: CmuxNextPages is not in the Linux tier).

Files written to the suite directory (`oracle.py` skips `_` files: these are vectors, not driver cases):

- `_envelopes.json`: JSON text messages. `verdict` is `valid` or `invalid` for the decoder; `encoded` is the
  canonical re-encoding of a valid one; `session_refusal` is the error code a session answers to a message the
  decoder accepts; `kind` is the message's `t` (null when there is none); `layer` is `session` or `transport`
  (`auth` and `bye`, consumed by an adapter before the session).
- `_frames.json`: binary data frames (`layer: data_frame`, `[u32 stream][u32 credit][payload]`) and the unix
  socket framing (`layer: unix`, a 4-byte length prefix with bit 31 for binary).
- `_tokens.json`: capability-token checks (`verify`, verdict `ok` or the TokenError name) and scope checks
  (`allows`, verdict `allowed` or `denied`), with the fixed test key.
- `_credit.json`: credit sequences. A `sender` sequence gives credit (a `credit` envelope or a data frame's credit
  field) and queues writes; each step names the bytes sent so far. A `receiver` sequence grants a window and
  receives frames; each receive names its verdict (`ok` or `cmux.protocol.credit_exceeded`).
- `_expectations.json`: per implementation, the categories it runs (or why not), the cases it skips with a
  reason, and the known divergences with their bug. A runner fails on any other mismatch and reports a listed
  divergence that conforms as an unexpected pass (Blink's TestExpectations rule), without failing.
- `coverage.json`: implementation x category pairs, covered or excluded with a reason (`oracle.py check
  --coverage`).

Bytes, hex and tokens come from the Rust lane's committed vectors
(cmux-tui/crates/cmux-pane-protocol/spec/pane-protocol-vectors.json, written by its encoders; its drift test
keeps it current). The cases below EXTRA_* and the credit sequences are written here by hand, with their verdicts.

Usage:
    gen_pane_protocol.py [--out DIR] [--check]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SOURCE = Path("cmux-tui/crates/cmux-pane-protocol/spec/pane-protocol-vectors.json")
DEFAULT_OUT = REPO / "tests" / "oracle" / "corpus" / "pane-protocol"
GENERATOR = "scripts/cmux-next/oracle/gen_pane_protocol.py"
SCHEMA = "cmux.oracle.pane-protocol/1"
CATEGORIES = ("envelopes", "frames", "tokens", "credit")
IMPLEMENTATIONS = ("rust", "ts", "swift")
CREDIT_EXCEEDED = "cmux.protocol.credit_exceeded"
MAX_OPID = 128

RUNNERS = {
    "rust": "cargo run -p cmux-pane-protocol --example conformance (in cmux-tui/)",
    "ts": "bun scripts/pane-protocol-conformance.ts (in webviews/)",
    "swift": "PaneProtocolConformanceTests in CmuxNextPagesTests (fleet)",
}

# Envelopes the hand list adds to the Rust lane's: decision 31's opid (TS and Swift check it) and the u32 bounds
# of `credit` bytes.
EXTRA_ENVELOPES: List[Dict[str, Any]] = [
    {
        "name": "call with opid",
        "text": '{"t":"call","id":1,"op":"cmux.git.status","params":{},"opid":"op-1:a.b_c"}',
        "verdict": "valid",
        "encoded": '{"t":"call","id":1,"op":"cmux.git.status","params":{},"opid":"op-1:a.b_c"}',
        "decision": 31,
    },
    {
        "name": "call with an empty opid",
        "text": '{"t":"call","id":1,"op":"cmux.git.status","opid":""}',
        "verdict": "invalid",
        "decision": 31,
    },
    {
        "name": "call with an opid of 129 characters",
        "text": '{"t":"call","id":1,"op":"cmux.git.status","opid":"' + "a" * (MAX_OPID + 1) + '"}',
        "verdict": "invalid",
        "decision": 31,
    },
    {
        "name": "call with an opid outside the alphabet",
        "text": '{"t":"call","id":1,"op":"cmux.git.status","opid":"a b"}',
        "verdict": "invalid",
        "decision": 31,
    },
    {
        "name": "credit of 0 bytes",
        "text": '{"t":"credit","stream":1,"bytes":0}',
        "verdict": "valid",
        "encoded": '{"t":"credit","stream":1,"bytes":0}',
    },
    {
        "name": "credit above u32",
        "text": '{"t":"credit","stream":1,"bytes":4294967296}',
        "verdict": "invalid",
    },
]

# The decoder lets these through; every session refuses them with this code.
SESSION_REFUSALS = {
    "call with non-object params (the session rejects them)": "cmux.protocol.invalid_params",
}

# Decisions T2 (plans/cmux-next/pane-protocol-decisions.md): a binary frame never names stream 0.
EXTRA_FRAMES: List[Dict[str, Any]] = [
    {
        "name": "data frame for stream 0",
        "layer": "data_frame",
        "hex": "000000000000000168",
        "verdict": "invalid",
    },
]

# Sender sequences: `credit` (an envelope) and `frame_credit` (a data frame's credit field) grant send credit;
# `write` queues bytes. `sent` is the payload bytes framed so far after the step.
SENDER_SEQUENCES: List[Dict[str, Any]] = [
    {"name": "no credit sends nothing", "steps": [{"write": 10, "sent": 0}]},
    {
        "name": "writes within the credit go out at once",
        "steps": [{"credit": 100, "sent": 0}, {"write": 40, "sent": 40}, {"write": 60, "sent": 100},
                  {"write": 1, "sent": 100}],
    },
    {
        "name": "a queued write waits for credit",
        "steps": [{"write": 50, "sent": 0}, {"credit": 20, "sent": 20}, {"credit": 100, "sent": 50}],
    },
    {
        "name": "a data frame's credit field is credit",
        "steps": [{"write": 10, "sent": 0}, {"frame_credit": 4, "sent": 4}, {"frame_credit": 0, "sent": 4},
                  {"credit": 6, "sent": 10}],
    },
    {"name": "credit of 0 is no credit", "steps": [{"credit": 0, "sent": 0}, {"write": 1, "sent": 0}]},
    {
        "name": "grants add up",
        "steps": [{"credit": 1, "sent": 0}, {"credit": 2, "sent": 0}, {"credit": 3, "sent": 0},
                  {"write": 10, "sent": 6}],
    },
    {
        "name": "a write larger than one frame follows the credit",
        "steps": [{"credit": 200000, "sent": 0}, {"write": 300000, "sent": 200000},
                  {"credit": 100000, "sent": 300000}],
    },
]

# Receiver sequences: the receiver grants `window` once; each frame's payload is `receive` bytes. A stream ends at
# its first credit violation, so no step follows one.
RECEIVER_SEQUENCES: List[Dict[str, Any]] = [
    {"name": "frames within the window", "window": 10, "steps": [{"receive": 4, "verdict": "ok"},
                                                                 {"receive": 6, "verdict": "ok"}]},
    {"name": "one byte over the window", "window": 10, "steps": [{"receive": 10, "verdict": "ok"},
                                                                 {"receive": 1, "verdict": CREDIT_EXCEEDED}]},
    {"name": "a frame larger than the window", "window": 10, "steps": [{"receive": 11, "verdict": CREDIT_EXCEEDED}]},
    {
        "name": "empty frames use no credit",
        "window": 0,
        "steps": [{"receive": 0, "verdict": "ok"}, {"receive": 0, "verdict": "ok"},
                  {"receive": 1, "verdict": CREDIT_EXCEEDED}],
    },
    {"name": "the default 256 KiB window", "window": 262144,
     "steps": [{"receive": 65536, "verdict": "ok"}, {"receive": 196608, "verdict": "ok"},
               {"receive": 1, "verdict": CREDIT_EXCEEDED}]},
]

# What each implementation runs. A category it does not run has a reason instead of "run".
CATEGORY_PLAN: Dict[str, Dict[str, str]] = {
    "rust": {category: "run" for category in CATEGORIES},
    "ts": {
        "envelopes": "run",
        "frames": "run",
        "tokens": "pages never verify capability tokens: the router and the providers do (Rust, Go)",
        "credit": "run",
    },
    "swift": {
        "envelopes": "run",
        "frames": "PageRouter carries JSON envelopes only: a page has no byte streams and no socket framing",
        "tokens": "the app never verifies capability tokens: the router and the providers do (Rust, Go)",
        "credit": "PageRouter has no byte streams, so no credit",
    },
}

# PageRouter (CmuxNextPages) is the Swift implementation: the host half of a page's bridge. It reads what a page
# sends the host (call, sub, unsub, cancel, and ok and err for host calls) and refuses anything else, so it runs
# every case but these kinds.
SWIFT_SKIP_REASONS = {
    "ev": "a page never sends `ev`: the host does",
    "release": "PageRouter has no handles to release",
    "open": "PageRouter has no byte streams",
    "credit": "PageRouter has no byte streams",
    "end": "PageRouter has no byte streams",
    "auth": "a page needs no auth: the host made its bridge",
    "bye": "a page's bridge ends with its document, not with `bye`",
}

OPID_BUG = "p15-oracle-213"
OPID_WHY = ("the Rust Envelope has no opid (decision 31): it ignores the field as unknown, so it neither checks it "
            "nor keeps it when it re-encodes")
DIVERGENCES: Dict[str, Dict[str, Dict[str, str]]] = {
    "rust": {
        "envelopes/call-with-opid": {"bug": OPID_BUG, "reason": OPID_WHY},
        "envelopes/call-with-an-empty-opid": {"bug": OPID_BUG, "reason": OPID_WHY},
        "envelopes/call-with-an-opid-of-129-characters": {"bug": OPID_BUG, "reason": OPID_WHY},
        "envelopes/call-with-an-opid-outside-the-alphabet": {"bug": OPID_BUG, "reason": OPID_WHY},
        "frames/data-frame-for-stream-0": {
            "bug": OPID_BUG,
            "reason": "DataFrame::decode takes any u32 stream id; decisions T2 says a binary frame never names stream 0",
        },
    },
    "ts": {},
    "swift": {
        case: {"bug": OPID_BUG, "reason": "PageRouter reads ids and replies without a shape check (the Swift side has no "
                                         "envelope decoder), so it answers what a decoder refuses"}
        for case in (
            "envelopes/call-id-0",
            "envelopes/id-above-2-53-1",
            "envelopes/negative-id",
            "envelopes/fractional-id",
            "envelopes/err-without-retryable",
            "envelopes/err-without-code",
            "envelopes/details-not-an-object",
        )
    },
}


class GenError(Exception):
    pass


def slug(name: str) -> str:
    text = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    if not text:
        raise GenError(f"case name {name!r} has no slug")
    return text


def message_kind(text: str) -> Optional[str]:
    try:
        value = json.loads(text)
    except ValueError:
        return None
    if isinstance(value, dict) and isinstance(value.get("t"), str):
        return value["t"]
    return None


def verdict(valid: Any) -> str:
    if not isinstance(valid, bool):
        raise GenError(f"`valid` must be a boolean, got {valid!r}")
    return "valid" if valid else "invalid"


def with_decision(case: Dict[str, Any], source: Dict[str, Any]) -> Dict[str, Any]:
    if "decision" in source:
        case["decision"] = source["decision"]
    return case


def envelope_cases(source: Dict[str, Any]) -> List[Dict[str, Any]]:
    cases: List[Dict[str, Any]] = []
    flat = [v for v in source["vectors"] if v.get("kind") == "envelope"]
    for layer, items in (("session", flat), ("transport", source["transport_envelopes"])):
        for item in items:
            case = {"id": "envelopes/" + slug(item["name"]), "name": item["name"], "layer": layer,
                    "kind": message_kind(item["text"]), "text": item["text"], "verdict": verdict(item["valid"])}
            if "encoded" in item:
                case["encoded"] = item["encoded"]
            if item["name"] in SESSION_REFUSALS:
                case["session_refusal"] = SESSION_REFUSALS[item["name"]]
            cases.append(with_decision(case, item))
    for item in EXTRA_ENVELOPES:
        case = {"id": "envelopes/" + slug(item["name"]), "name": item["name"], "layer": "session",
                "kind": message_kind(item["text"]), "text": item["text"], "verdict": item["verdict"]}
        if "encoded" in item:
            case["encoded"] = item["encoded"]
        cases.append(with_decision(case, item))
    missing = set(SESSION_REFUSALS) - {c["name"] for c in cases}
    if missing:
        raise GenError(f"SESSION_REFUSALS names cases the vectors no longer have: {sorted(missing)}")
    return cases


def frame_cases(source: Dict[str, Any]) -> List[Dict[str, Any]]:
    cases: List[Dict[str, Any]] = []
    for item in (v for v in source["vectors"] if v.get("kind") == "data_frame"):
        case = {"id": "frames/" + slug(item["name"]), "name": item["name"], "layer": "data_frame",
                "hex": item["hex"], "verdict": verdict(item["valid"])}
        if item["valid"]:
            case["frame"] = {"stream": item["stream"], "credit": item["credit"], "payload_hex": item["payload_hex"]}
        cases.append(with_decision(case, item))
    for item in source["unix_framing"]:
        case = {"id": "frames/" + slug(item["name"]), "name": item["name"], "layer": "unix", "hex": item["hex"],
                "verdict": verdict(item["valid"]), "header_only": bool(item.get("header_only", False))}
        if item["valid"] and not case["header_only"]:
            if item["kind"] == "text":
                case["message"] = {"kind": "text", "text": item["text"]}
            else:
                case["message"] = {"kind": "binary", "frame": item["data_frame"]}
        cases.append(with_decision(case, item))
    for item in EXTRA_FRAMES:
        cases.append({"id": "frames/" + slug(item["name"]), "name": item["name"], "layer": item["layer"],
                      "hex": item["hex"], "verdict": item["verdict"]})
    return cases


def token_file(source: Dict[str, Any]) -> Dict[str, Any]:
    token = source["token"]
    cases: List[Dict[str, Any]] = []
    for check in token["checks"]:
        cases.append(with_decision({
            "id": "tokens/" + slug(check["name"]), "name": check["name"], "kind": "verify", "token": check["token"],
            "aud": check["aud"], "origin": check["origin"], "now": check["now"], "verdict": check["result"],
        }, check))
    for allow in token["allows"]:
        name = f"{allow['scope']} for {allow['op']}"
        cases.append({"id": "tokens/allows-" + slug(name), "name": name, "kind": "allows", "op": allow["op"],
                      "scope": allow["scope"], "verdict": "allowed" if allow["allowed"] else "denied"})
    key = {k: token[k] for k in ("format", "header", "origin_rule", "seed_hex", "public_key_hex", "claims", "token")}
    return {"key": key, "cases": cases}


def credit_cases() -> List[Dict[str, Any]]:
    cases: List[Dict[str, Any]] = []
    for sequence in SENDER_SEQUENCES:
        for step in sequence["steps"]:
            actions = [k for k in ("credit", "frame_credit", "write") if k in step]
            if len(actions) != 1 or set(step) != {actions[0], "sent"}:
                raise GenError(f"{sequence['name']}: a sender step is one of credit, frame_credit, write and its sent")
        cases.append({"id": "credit/sender-" + slug(sequence["name"]), "name": sequence["name"], "role": "sender",
                      "steps": sequence["steps"]})
    for sequence in RECEIVER_SEQUENCES:
        steps = sequence["steps"]
        for index, step in enumerate(steps):
            if set(step) != {"receive", "verdict"} or step["verdict"] not in ("ok", CREDIT_EXCEEDED):
                raise GenError(f"{sequence['name']}: a receiver step is a receive and its verdict")
            if step["verdict"] != "ok" and index != len(steps) - 1:
                raise GenError(f"{sequence['name']}: a credit violation ends the stream, so it is the last step")
        cases.append({"id": "credit/receiver-" + slug(sequence["name"]), "name": sequence["name"],
                      "role": "receiver", "window": sequence["window"], "steps": steps})
    return cases


def expectations(categories: Dict[str, List[Dict[str, Any]]]) -> Dict[str, Any]:
    ids = {case["id"] for cases in categories.values() for case in cases}
    out: Dict[str, Any] = {}
    for impl in IMPLEMENTATIONS:
        skip: Dict[str, str] = {}
        if impl == "ts":
            for case in categories["envelopes"]:
                if case["layer"] == "transport":
                    skip[case["id"]] = "the TS adapters take auth and bye before the session: decodeEnvelope never sees them"
            for case in categories["frames"]:
                if case["layer"] == "unix":
                    skip[case["id"]] = "pages talk over WebSocket and MessagePort, which frame each message themselves"
        if impl == "swift":
            for case in categories["envelopes"]:
                if case["kind"] in SWIFT_SKIP_REASONS:
                    skip[case["id"]] = SWIFT_SKIP_REASONS[case["kind"]]
        divergences = DIVERGENCES[impl]
        unknown = sorted((set(divergences) | set(skip)) - ids)
        if unknown:
            raise GenError(f"{impl}: expectations name cases that do not exist: {unknown}")
        both = sorted(set(divergences) & set(skip))
        if both:
            raise GenError(f"{impl}: a case is either skipped or a divergence, not both: {both}")
        out[impl] = {"runner": RUNNERS[impl], "categories": CATEGORY_PLAN[impl], "skip": skip,
                     "divergences": divergences}
    return {"schema": SCHEMA, "generator": GENERATOR, "implementations": out}


def coverage(categories: Dict[str, List[Dict[str, Any]]], source_sha: str) -> Dict[str, Any]:
    excluded = {f"{impl}:{category}": plan for impl in IMPLEMENTATIONS
                for category, plan in CATEGORY_PLAN[impl].items() if plan != "run"}
    total = len(IMPLEMENTATIONS) * len(CATEGORIES)
    return {
        "generator": GENERATOR,
        "suite": "pane-protocol",
        "source": SOURCE.as_posix(),
        "source_sha256": source_sha,
        "unit": "implementation:category",
        "cases": {category: len(cases) for category, cases in categories.items()},
        "verdicts": "not run",
        "total": total,
        "covered": total - len(excluded),
        "excluded": excluded,
        "missing": [],
    }


def build(repo: Path) -> Dict[str, Any]:
    raw = (repo / SOURCE).read_bytes()
    source = json.loads(raw)
    tokens = token_file(source)
    categories = {"envelopes": envelope_cases(source), "frames": frame_cases(source), "tokens": tokens["cases"],
                  "credit": credit_cases()}
    seen: Dict[str, str] = {}
    for cases in categories.values():
        for case in cases:
            if case["id"] in seen:
                raise GenError(f"{case['id']}: two cases have this id ({seen[case['id']]!r}, {case['name']!r})")
            seen[case["id"]] = case["name"]
    files: Dict[str, Any] = {}
    for category, cases in categories.items():
        body: Dict[str, Any] = {"schema": SCHEMA, "category": category, "generator": GENERATOR,
                                "source": SOURCE.as_posix()}
        if category == "tokens":
            body["key"] = tokens["key"]
        body["cases"] = cases
        files[f"_{category}.json"] = body
    files["_expectations.json"] = expectations(categories)
    files["coverage.json"] = coverage(categories, hashlib.sha256(raw).hexdigest())
    return files


def render(value: Any) -> str:
    return json.dumps(value, indent=2, ensure_ascii=False) + "\n"


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="suite directory (default %(default)s)")
    parser.add_argument("--repo", type=Path, default=REPO, help="repository root that holds the Rust vectors")
    parser.add_argument("--check", action="store_true", help="exit 1 when the committed files are stale")
    args = parser.parse_args(argv)
    try:
        files = build(args.repo)
    except (GenError, KeyError, OSError, ValueError) as error:
        print(f"gen_pane_protocol: {error}", file=sys.stderr)
        return 2
    stale = []
    for name, value in files.items():
        path = args.out / name
        text = render(value)
        current = path.read_text(encoding="utf-8") if path.is_file() else None
        if current == text:
            continue
        stale.append(name)
        if not args.check:
            args.out.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
    if args.check and stale:
        print(f"gen_pane_protocol: stale in {args.out}: {', '.join(stale)} (run {GENERATOR})", file=sys.stderr)
        return 1
    cases = sum(len(files[f"_{c}.json"]["cases"]) for c in CATEGORIES)
    verb = "up to date" if not stale else ("stale" if args.check else f"wrote {len(stale)} files")
    print(f"gen_pane_protocol: {cases} cases in {len(CATEGORIES)} categories, {verb}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
