#!/usr/bin/env python3
"""Recorded agent-stream fixtures for perf100 (no live model calls).

A fixture is a JSON Lines file: one object per `agent_message_chunk`, `{"ms": <offset from
the turn start>, "text": <delta>}`. The three committed fixtures (`agent-streams/*.jsonl`)
are made by `generate()` from a fixed seed, and MANIFEST.json pins their sha256, so every
run streams the same bytes at the same cadence. Their shape follows what Claude Code and
Codex send through ACP: Markdown prose, lists, tables and fenced code; deltas of 1 to 6
words (2 to 60 bytes, a few longer ones for code lines); about 60-90 words a second, with
short pauses at paragraph and block ends.

  streams.py generate   # rewrites agent-streams/*.jsonl and MANIFEST.json (deterministic)
  streams.py verify     # exit 1 when a committed fixture differs from its manifest digest
"""
from __future__ import annotations

import hashlib
import json
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DIR = os.path.join(HERE, "agent-streams")
MANIFEST = os.path.join(DIR, "MANIFEST.json")

# name: (seed, target bytes, code share)
FIXTURES = {
    "prose-8k": (101, 8_000, 0.1),
    "mixed-24k": (202, 24_000, 0.35),
    "code-48k": (303, 48_000, 0.6),
}

WORDS = ("the daemon terminal session agent buffer render frame socket journal state store reply token "
         "workspace pane tab layout cursor scroll output input queue thread memory disk write read cache "
         "event handler stream chunk diff patch test build commit review owner lane budget metric idle "
         "latency throughput process window snapshot schema protocol client server host path file line "
         "value key index range batch flush sync async await error retry timeout backoff limit").split()
LANGS = ("rust", "swift", "ts", "python", "sh")
IDENTS = ("session", "buffer", "frame", "state", "writer", "reader", "cursor", "pane", "tab", "store")


def _sentence(rng: random.Random) -> str:
    words = [rng.choice(WORDS) for _ in range(rng.randint(6, 18))]
    if rng.random() < 0.3:
        i = rng.randrange(len(words))
        words[i] = f"`{rng.choice(IDENTS)}_{rng.choice(IDENTS)}`"
    if rng.random() < 0.15:
        i = rng.randrange(len(words))
        words[i] = f"**{words[i]}**"
    return words[0].capitalize() + " " + " ".join(words[1:]) + "."


def _code_line(rng: random.Random, lang: str, depth: int) -> str:
    a, b = rng.choice(IDENTS), rng.choice(IDENTS)
    pad = "    " * depth
    forms = {
        "rust": [f"let {a} = {b}.{rng.choice(WORDS)}()?;", f"if {a}.is_empty() {{ return Ok(()); }}",
                 f"for {a} in {b}.iter() {{ {a}.flush()?; }}", f"match {a} {{ Some(x) => x, None => {b} }};"],
        "swift": [f"let {a} = try await {b}.{rng.choice(WORDS)}()", f"guard let {a} else {{ return }}",
                  f"for {a} in {b} {{ {a}.flush() }}", f"@MainActor func {a}{b.capitalize()}() {{}}"],
        "ts": [f"const {a} = await {b}.{rng.choice(WORDS)}();", f"if (!{a}) return;",
               f"for (const {a} of {b}) {a}.flush();", f"export function {a}({b}: string) {{}}"],
        "python": [f"{a} = {b}.{rng.choice(WORDS)}()", f"if not {a}:", f"for {a} in {b}:",
                   f"def {a}_{b}(self, {b}):"],
        "sh": [f"{a}=\"$({b} --json)\"", f"[ -n \"${a}\" ] || exit 1", f"for {a} in ${b}; do echo \"${a}\"; done"],
    }
    return pad + rng.choice(forms[lang])


def _blocks(rng: random.Random, target: int, code_share: float):
    size = 0
    heading = 0
    while size < target:
        roll = rng.random()
        if roll < code_share:
            lang = rng.choice(LANGS)
            lines = [_code_line(rng, lang, rng.randint(0, 2)) for _ in range(rng.randint(4, 24))]
            block = f"```{lang}\n" + "\n".join(lines) + "\n```"
        elif roll < code_share + 0.12:
            heading += 1
            block = f"{'#' * rng.randint(2, 3)} {heading}. {' '.join(rng.choice(WORDS) for _ in range(rng.randint(2, 5)))}"
        elif roll < code_share + 0.25:
            block = "\n".join(f"- {_sentence(rng)}" for _ in range(rng.randint(2, 6)))
        elif roll < code_share + 0.3:
            cols = rng.randint(2, 4)
            rows = [" | ".join(rng.choice(WORDS) for _ in range(cols)) for _ in range(rng.randint(2, 6))]
            block = "\n".join([f"| {rows[0]} |", "|" + "---|" * cols] + [f"| {r} |" for r in rows[1:]])
        else:
            block = " ".join(_sentence(rng) for _ in range(rng.randint(2, 6)))
        size += len(block) + 2
        yield block


def generate_one(seed: int, target: int, code_share: float) -> list[dict]:
    rng = random.Random(seed)
    text = "\n\n".join(_blocks(rng, target, code_share)) + "\n"
    chunks = []
    ms = 0.0
    i = 0
    while i < len(text):
        in_code = text.count("```", 0, i) % 2 == 1
        if in_code and rng.random() < 0.5:
            end = text.find("\n", i)
            end = len(text) if end < 0 else end + 1
        else:
            end = i
            for _ in range(rng.randint(1, 6)):
                nxt = text.find(" ", end + 1)
                end = len(text) if nxt < 0 else nxt
            end = min(len(text), max(end, i + 2))
        piece = text[i:end]
        words = max(1, piece.count(" ") + piece.count("\n"))
        ms += words * rng.uniform(11.0, 17.0)  # about 60-90 words a second
        if piece.endswith("\n\n") or piece.endswith("```\n"):
            ms += rng.uniform(40.0, 160.0)
        chunks.append({"ms": round(ms, 1), "text": piece})
        i = end
    return chunks


def _encode(chunks: list[dict]) -> bytes:
    return "".join(json.dumps(c, ensure_ascii=False, separators=(",", ":")) + "\n" for c in chunks).encode()


def generate():
    os.makedirs(DIR, exist_ok=True)
    manifest = {}
    for name, (seed, target, share) in FIXTURES.items():
        data = _encode(generate_one(seed, target, share))
        with open(os.path.join(DIR, f"{name}.jsonl"), "wb") as handle:
            handle.write(data)
        chunks = data.count(b"\n")
        last = json.loads(data.splitlines()[-1])
        manifest[name] = {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data), "chunks": chunks,
                          "text_bytes": sum(len(json.loads(l)["text"].encode()) for l in data.splitlines()),
                          "duration_ms": last["ms"], "seed": seed}
    with open(MANIFEST, "w") as handle:
        json.dump(manifest, handle, indent=2, sort_keys=True)
        handle.write("\n")
    return manifest


def load(name: str) -> list[dict]:
    with open(os.path.join(DIR, f"{name}.jsonl"), "rb") as handle:
        return [json.loads(line) for line in handle.read().splitlines() if line]


def verify() -> dict:
    """{name: sha256} of every fixture; raises SystemExit when one differs from MANIFEST.json."""
    with open(MANIFEST) as handle:
        manifest = json.load(handle)
    out = {}
    for name, entry in manifest.items():
        with open(os.path.join(DIR, f"{name}.jsonl"), "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
        if digest != entry["sha256"]:
            raise SystemExit(f"perf100: fixture {name} differs from MANIFEST.json ({digest} != {entry['sha256']})")
        out[name] = digest
    return out


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "verify"
    if command == "generate":
        print(json.dumps(generate(), indent=2))
    elif command == "verify":
        print(json.dumps(verify(), indent=2))
    else:
        raise SystemExit("usage: streams.py generate|verify")
