#!/usr/bin/env python3
"""A seeded Claude Code or Codex transcript shaped like Leo's coordinator chat.

Leo, 2026-11-12: "are you guys able to simulate my god-chats? like a true gb-level history sample".
The shape is measured on his Mac (content never leaves it; only counts and sizes do): 1.096 GB in
272,147 lines, 99 of them over 1 MB, sixteen line types with their own size spread (SHAPE below,
p50/p90/p99/max/sum per type), and the content blocks of the user and assistant lines (text,
tool_use, tool_result, thinking, image).

--scale multiplies the line counts (0.1, 1, 3 show the slope); every type keeps its size spread.
The same --seed and --scale write the same bytes. Each type's sizes follow its quantiles: log
interpolation between p50, p90 and p99, and a tail from p99 to max whose steepness is solved so the
type's bytes match its measured sum. The file is a real transcript to a reader: a uuid/parentUuid
chain, a session id, a cwd, timestamps, assistant tool_use blocks answered by user tool_result
blocks with the same id, and images as base64 PNG blocks.

--format codex writes a Codex rollout (session_meta, turn_context, response_item, event_msg) of the
same bytes and spread, with the user and assistant sizes mapped onto its records.

Prints one JSON summary line (bytes, lines, lines over 1 MB, each type's achieved p50/p90/p99/max/sum
next to the target), so a run shows how close it came.

    gen_transcript.py --out god.jsonl [--scale 1] [--seed 1] [--format claude|codex] [--cwd DIR]
"""

from __future__ import annotations

import argparse
import base64
import datetime
import json
import math
import random
import sys
from pathlib import Path

# Leo's coordinator Claude Code JSONL, 2026-11-12: lines per type and line bytes per type.
TOTAL_BYTES = 1_095_957_657
TOTAL_LINES = 272_147
OVER_1MB = 99
SHAPE = {
    "queue-operation": (69673, 553, 1331, 4837, 91400, 51656981),
    "assistant": (47328, 2107, 3259, 4825, 15189, 108591098),
    "user": (34646, 1378, 4639, 83785, 4154812, 265647059),
    "api-request": (31991, 1330, 1397, 1397, 42958, 44835523),
    "attachment": (23453, 2325, 7205, 258640, 2736917, 243909607),
    "api-request-blob": (18485, 1708, 5898, 464434, 4156638, 351445137),
    "pr-link": (12925, 217, 237, 237, 239, 2890097),
    "last-prompt": (11348, 343, 345, 347, 351, 3552050),
    "atis-latch": (11347, 83, 83, 83, 83, 941801),
    "system": (10136, 1291, 1309, 1893, 3299, 12947851),
    "custom-title": (205, 108, 108, 108, 108, 22140),
    "agent-name": (205, 104, 104, 104, 104, 21320),
    "mode": (204, 83, 83, 83, 83, 16932),
    "api-request-shape": (155, 64263, 66252, 69027, 72740, 9456807),
    "tools-used": (43, 400, 743, 837, 837, 18294),
    "cost-state": (3, 1559, 1842, 1842, 1842, 4960),
}
# Content blocks across the user and assistant lines.
BLOCKS = {"text": 36208, "tool_use": 28873, "tool_result": 28531, "thinking": 14436, "image": 2779}

MB = 1 << 20


def quantile_sizes(rng: random.Random, n: int, p50: int, p90: int, p99: int, mx: int, total: int) -> list[int]:
    """`n` sizes whose p50, p90, p99 and max are the measured ones and whose sum is near `total`."""
    if n == 0:
        return []
    lo = max(16, int(p50 * 0.35)) if p50 < p90 else p50
    us = [rng.random() for _ in range(n)]

    def interp(u: float, k: float) -> float:
        def seg(a: float, b: float, t: float) -> float:
            if a <= 0 or b <= 0 or a == b:
                return a + (b - a) * t
            return math.exp(math.log(a) + (math.log(b) - math.log(a)) * t)

        if u < 0.5:
            return seg(lo, p50, u / 0.5)
        if u < 0.9:
            return seg(p50, p90, (u - 0.5) / 0.4)
        if u < 0.99:
            return seg(p90, p99, (u - 0.9) / 0.09)
        return seg(p99, mx, ((u - 0.99) / 0.01) ** k)

    # Solve the tail's steepness k so the sum lands on the measured one (bisection on log k).
    def sizes_for(k: float) -> list[int]:
        return [int(interp(u, k)) for u in us]

    lo_k, hi_k = math.log(0.05), math.log(400.0)
    best = sizes_for(1.0)
    for _ in range(40):
        mid = (lo_k + hi_k) / 2
        best = sizes_for(math.exp(mid))
        if sum(best) > total:
            lo_k = mid
        else:
            hi_k = mid
    # The largest line is the measured max, so a 1x run carries its 4 MB lines.
    if n >= 100 and mx > p99:
        best[max(range(n), key=lambda i: us[i])] = mx
    return best


class Filler:
    """Deterministic text and base64 to pad a line to its size, sliced from one seeded buffer."""

    WORDS = (
        "the cargo test passed failed error warning src lib fn let mut impl struct pub use crate "
        "acpmux hub list guard startup store session event record seq reply peer link watch "
        "frame pane chat transcript turn tool result output stdout stderr exit code diff"
    ).split()

    def __init__(self, rng: random.Random, size: int = 8 * MB):
        parts: list[str] = []
        n = 0
        while n < size:
            w = rng.choice(self.WORDS)
            sep = "\\n" if rng.random() < 0.08 else ('\\"' if rng.random() < 0.01 else " ")
            parts.append(w)
            parts.append(sep)
            n += len(w) + len(sep)
        self.text = "".join(parts)
        self.b64 = base64.b64encode(rng.randbytes(6 * MB)).decode()
        self.rng = rng

    def text_of(self, n: int) -> str:
        """`n` characters of JSON-escaped text (never ending inside an escape)."""
        out = []
        while n > 0:
            start = self.rng.randrange(1, len(self.text) - 1)
            if self.text[start - 1] == "\\":
                start += 1  # never begin inside an escape
            piece = self.text[start : start + n]
            if piece.endswith("\\"):
                piece = piece[:-1]  # nor end inside one
            if not piece:
                break
            out.append(piece)
            n -= len(piece)
        return "".join(out)

    def b64_of(self, n: int) -> str:
        n -= n % 4
        out = []
        while n > 0:
            start = self.rng.randrange(0, len(self.b64) // 4) * 4
            piece = self.b64[start : start + n]
            piece = piece[: len(piece) - len(piece) % 4]
            out.append(piece)
            n -= len(piece)
        return "".join(out)


PAD = "\u0000PAD\u0000"
PAD_JSON = json.dumps(PAD)


def fill(line: dict, size: int, filler: Filler, b64: bool = False) -> str:
    """`line` as JSON with its one PAD string grown so the line is about `size` bytes."""
    skeleton = json.dumps(line, separators=(",", ":"))
    room = max(0, size - (len(skeleton) - len(PAD_JSON) + 2))
    body = filler.b64_of(room) if b64 else filler.text_of(room)
    return skeleton.replace(PAD_JSON, '"' + body + '"', 1)


def claude_lines(scale: float, seed: int, cwd: str):
    rng = random.Random(seed)
    filler = Filler(random.Random(seed ^ 0x5EED))
    session = "00000000-0000-4000-8000-%012d" % seed
    counts = {t: max(1 if scale >= 1 else 0, round(s[0] * scale)) for t, s in SHAPE.items()}
    sizes = {
        t: quantile_sizes(rng, counts[t], s[1], s[2], s[3], s[4], int(s[5] * counts[t] / s[0]))
        for t, s in SHAPE.items()
    }
    # Blocks: assistant lines carry thinking, text or tool_use; user lines carry tool_result (some
    # with an image), or a prompt's text.
    a_n, u_n = counts["assistant"], counts["user"]
    tr = min(u_n, round(BLOCKS["tool_result"] * scale))
    img = round(BLOCKS["image"] * scale)
    a_kinds = ["tool_use"] * round(BLOCKS["tool_use"] * scale) + ["thinking"] * round(BLOCKS["thinking"] * scale)
    a_kinds += ["text"] * max(0, a_n - len(a_kinds))
    a_kinds = a_kinds[:a_n]
    rng.shuffle(a_kinds)
    # User lines: prompts and tool results, each a queue in time order. The largest sizes are the
    # lines with an image (screenshots), the rest are spread at random.
    u_sizes = sorted(sizes["user"])
    big, rest = u_sizes[u_n - img :] if img else [], u_sizes[: u_n - img]
    rng.shuffle(rest)
    entries = [(sz, True) for sz in big] + [(sz, False) for sz in rest]
    results_q = entries[:tr]
    prompts_q = entries[tr:]
    rng.shuffle(results_q)
    rng.shuffle(prompts_q)

    remaining = dict(counts)
    idx = {t: 0 for t in SHAPE}
    pending_tools: list[str] = []
    parent = None
    t0 = 1_790_000_000  # 2026-09
    clock = 0.0
    n = 0
    a_i = 0
    while any(remaining.values()):
        # The grammar: a tool_use is answered by a tool_result before the next prompt; otherwise
        # pick a type in proportion to what is left.
        if pending_tools and remaining["user"] and results_q:
            kind = "user"
        else:
            # A free pick of "user" is a prompt: the tool results wait for their tool_use.
            weights = {k: (len(prompts_q) if k == "user" else v) for k, v in remaining.items()}
            total = sum(weights.values())
            if total == 0:
                kind = "user"
            else:
                r = rng.random() * total
                for kind, left in weights.items():
                    r -= left
                    if r < 0:
                        break
        remaining[kind] -= 1
        size = sizes[kind][idx[kind]]
        idx[kind] += 1
        n += 1
        clock += rng.expovariate(1 / 3.0)
        ts = t0 + clock
        stamp = datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
        uuid = "%08x-0000-4000-9000-%012d" % (seed & 0xFFFFFFFF, n)
        base = {"type": kind, "uuid": uuid, "parentUuid": parent, "sessionId": session, "timestamp": stamp, "cwd": cwd}
        b64 = False
        if kind == "assistant":
            ak = a_kinds[a_i] if a_i < len(a_kinds) else "text"
            a_i += 1
            if ak == "tool_use":
                call = "toolu_%016x%08d" % (rng.getrandbits(64), n)
                pending_tools.append(call)
                block = {"type": "tool_use", "id": call, "name": rng.choice(["Bash", "Read", "Edit", "Grep", "Agent"]), "input": {"command": PAD}}
            elif ak == "thinking":
                block = {"type": "thinking", "thinking": PAD, "signature": "sig"}
            else:
                block = {"type": "text", "text": PAD}
            base["message"] = {"id": "msg_%d" % n, "role": "assistant", "model": "claude-opus-5-5", "content": [block],
                               "usage": {"input_tokens": 3, "cache_read_input_tokens": 150000, "output_tokens": 412}}
            parent = uuid
        elif kind == "user":
            # A pending tool_use is answered first; otherwise a prompt, or a result when no prompt is left.
            take_result = bool(pending_tools and results_q) or not prompts_q
            size, image = (results_q if take_result else prompts_q).pop()
            if take_result:
                call = pending_tools.pop(0) if pending_tools else "toolu_orphan_%08d" % n
                if image:
                    content = [{"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": PAD}}]
                    b64 = True
                else:
                    content = PAD
                base["message"] = {"role": "user", "content": [{"type": "tool_result", "tool_use_id": call, "content": content}]}
                base["toolUseResult"] = {"stdout": "", "stderr": "", "interrupted": False}
            else:
                pending_tools.clear()
                if image:
                    base["message"] = {"role": "user", "content": [{"type": "text", "text": "look"}, {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": PAD}}]}
                    b64 = True
                else:
                    base["message"] = {"role": "user", "content": PAD}
            parent = uuid
        elif kind == "queue-operation":
            base = {"type": kind, "operation": rng.choice(["enqueue", "dequeue", "remove"]), "timestamp": stamp, "sessionId": session, "content": PAD}
        elif kind in ("api-request", "api-request-blob", "api-request-shape"):
            base = {"type": kind, "requestId": "req_%d" % n, "timestamp": stamp, "sessionId": session, "body": PAD}
        elif kind == "attachment":
            base["attachment"] = {"type": rng.choice(["file", "hook_additional_context", "todo", "skill_listing"]), "content": PAD}
        elif kind == "system":
            base.update({"subtype": "informational", "level": "info", "content": PAD})
        elif kind == "pr-link":
            base = {"type": kind, "sessionId": session, "url": PAD}
        elif kind == "last-prompt":
            base = {"type": kind, "sessionId": session, "lastPrompt": PAD}
        elif kind == "custom-title":
            base = {"type": kind, "sessionId": session, "customTitle": PAD}
        elif kind == "agent-name":
            base = {"type": kind, "sessionId": session, "agentName": PAD}
        else:
            base = {"type": kind, "sessionId": session, "value": PAD}
        yield kind, fill(base, size, filler, b64)


CODEX_MAP = {
    # Codex record shape for each Claude line type of the same size spread.
    "user": ("response_item", "function_call_output"),
    "assistant": ("response_item", "message"),
    "attachment": ("event_msg", "exec_command_end"),
    "api-request-blob": ("response_item", "function_call_output"),
    "queue-operation": ("event_msg", "token_count"),
    "api-request": ("turn_context", None),
    "system": ("event_msg", "agent_reasoning"),
}


def codex_lines(scale: float, seed: int, cwd: str):
    filler = Filler(random.Random(seed ^ 0xC0DE))
    yield "session_meta", json.dumps({"timestamp": "2026-09-01T00:00:00.000Z", "type": "session_meta",
                                      "payload": {"id": "00000000-0000-4000-8000-%012d" % seed, "cwd": cwd, "originator": "codex_cli_rs", "cli_version": "0.99.0"}})
    for kind, line in claude_lines(scale, seed, cwd):
        size = len(line)
        rtype, sub = CODEX_MAP.get(kind, ("event_msg", "background_event"))
        payload: dict = {"type": sub} if sub else {"cwd": cwd, "model": "gpt-6.1", "approval_policy": "never"}
        if sub == "function_call_output":
            payload.update({"call_id": "call_%d" % size, "output": PAD})
        elif sub == "message":
            payload.update({"role": "assistant", "content": [{"type": "output_text", "text": PAD}]})
        elif sub is None:
            payload["summary"] = PAD
        else:
            payload["message"] = PAD
        yield rtype, fill({"timestamp": "2026-09-01T00:00:00.000Z", "type": rtype, "payload": payload}, size, filler)


def pct(sorted_sizes: list[int], q: float) -> int:
    return sorted_sizes[min(len(sorted_sizes) - 1, int(q * len(sorted_sizes)))] if sorted_sizes else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True)
    ap.add_argument("--scale", type=float, default=1.0)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--format", choices=["claude", "codex"], default="claude")
    ap.add_argument("--cwd", default="/home/agent/work/coordinator")
    args = ap.parse_args()
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    gen = claude_lines if args.format == "claude" else codex_lines
    by_type: dict[str, list[int]] = {}
    total = lines = big = 0
    with out.open("w", buffering=4 * MB) as f:
        for kind, line in gen(args.scale, args.seed, args.cwd):
            f.write(line)
            f.write("\n")
            n = len(line) + 1
            total += n
            lines += 1
            big += n > MB
            by_type.setdefault(kind, []).append(n)
    summary = {"out": str(out), "format": args.format, "scale": args.scale, "seed": args.seed, "bytes": total, "lines": lines,
               "lines_over_1MB": big, "target": {"bytes": int(TOTAL_BYTES * args.scale), "lines": int(TOTAL_LINES * args.scale), "lines_over_1MB": round(OVER_1MB * args.scale)}, "types": {}}
    for kind, sizes in sorted(by_type.items(), key=lambda kv: -len(kv[1])):
        s = sorted(sizes)
        row = {"n": len(s), "p50": pct(s, 0.5), "p90": pct(s, 0.9), "p99": pct(s, 0.99), "max": s[-1], "sum": sum(s)}
        if args.format == "claude" and kind in SHAPE:
            t = SHAPE[kind]
            row["target"] = {"n": round(t[0] * args.scale), "p50": t[1], "p90": t[2], "p99": t[3], "max": t[4], "sum": round(t[5] * args.scale)}
        summary["types"][kind] = row
    print(json.dumps(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
