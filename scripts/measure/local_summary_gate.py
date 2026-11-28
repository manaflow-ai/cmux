#!/usr/bin/env python3
"""Local session-summary gate: can a small on-device model write the sidebar's one-line session summary?

hq docs/findings/2026-11-20-local-model-session-summary.md set the gate this measures. A model adapter (a
`titles.command`-shaped program: request on stdin, one line on stdout) is admitted only when, on the labeled set of
30 real, redacted agent sessions in fixtures/local-summary/sessions.jsonl, the smallest installed model has
  warm p95 < 150 ms, cold p95 < 500 ms, every output < 160 characters, and zero unsupported status claims.

Runtimes it looks for, in this order, and the smallest model each one has installed (it installs nothing):
  ollama (its HTTP API on 127.0.0.1:11434, or `ollama serve` started for the run), llama-server/llama-cli with a GGUF
  under ~/models, ~/.cache/huggingface, ~/.cache/lm-studio or ~/.lmstudio, and mlx_lm with an mlx-community model in
  the Hugging Face cache. With none, the verdict is `no-runtime`: the finding says stop at the adapter contract and add
  no model dependency to the app.

`baseline` is the finding's deterministic first pass (status keywords and the PR numbers of the reply's first
sentence): its numbers are the comparison row, and it runs anywhere.

Usage:
  local_summary_gate.py [--runtime auto|baseline|ollama|llama|mlx] [--model NAME] [--fixtures F] [--out DIR] [--strict]
Prints the report as JSON on stdout (and writes report.json, raw.jsonl and report.md to --out or $FAST_CHECKS_OUT).
Exits 0 with a verdict (pass, fail, no-runtime); --strict exits 1 unless the verdict is pass.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import platform
import re
import shutil
import socket
import statistics
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures" / "local-summary" / "sessions.jsonl"
STATUSES = ("working", "waiting", "blocked", "done", "idle")
GATE = {"warm_p95_ms": 150.0, "cold_p95_ms": 500.0, "max_chars": 160, "unsupported": 0}
MAX_TOKENS = 48
WARM_ROUNDS = 3

PROMPT = """You write the one-line status of an agent session for a sidebar row.
Reply with one line under 160 characters and nothing else. Start with exactly one of these words and a colon:
working, waiting, blocked, done, idle. Then say what the session did or is doing, naming the PR numbers it names.
Claim nothing the session did not say.

The last message the session got:
{prompt}

The session's last reply:
{reply}

Status line:"""


def load(path: Path) -> list[dict]:
    rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    if len(rows) < 30:
        raise SystemExit(f"local_summary_gate: {path} has {len(rows)} labeled sessions; the gate needs at least 30")
    return rows


def request(case: dict) -> str:
    return PROMPT.format(prompt=case["prompt"][:300], reply=case["reply"][:1400])


def clean(text: str) -> str:
    line = next((ln.strip() for ln in text.strip().splitlines() if ln.strip()), "")
    return line.strip("\"'` ")


# ---- scoring -------------------------------------------------------------------------------------------------------

def status_of(line: str) -> str | None:
    m = re.match(r"\W*(\w+)", line.lower())
    return m.group(1) if m and m.group(1) in STATUSES else None


def score(case: dict, line: str) -> dict:
    label = case["label"]
    low = line.lower()
    said = status_of(line)
    facts = label["facts"]
    hit = sum(1 for alts in facts if any(a.lower() in low for a in alts))
    false = [p for p in label.get("false_claims", []) if re.search(p, low)]
    # An unsupported status claim: a status word that is not the session's, no status word at all, or a sentence the
    # session contradicts (its false_claims: "#43444 merged" while the reply says it is not).
    unsupported = (said != label["status"]) or bool(false)
    return {"status": said, "status_ok": said == label["status"], "facts_hit": hit, "facts": len(facts),
            "false_claims": false, "unsupported": unsupported, "chars": len(line)}


# ---- runtimes ------------------------------------------------------------------------------------------------------

class Baseline:
    """The finding's no-dependency first pass, as an in-process call (warm) and a fresh process (cold)."""
    name = "baseline"
    model = "deterministic-keywords"
    version = "1"

    RULES = (("blocked", r"\b(can't|cannot|couldn't|still red|refused|blocked|fail(ed|s)?)\b"),
             ("waiting", r"\b(waiter|waiting|queued|land queue|will tell me|once ci)\b"),
             ("idle", r"\b(stopped|nothing (more )?to do|no action|taking no action|closed the session)\b"),
             ("done", r"\b(merged|is met|done|finished)\b"))

    def summarize(self, req: str) -> str:
        reply = req.split("The session's last reply:\n", 1)[-1].split("\n\nStatus line:", 1)[0]
        first = re.split(r"(?<=[.!?])\s", reply.strip(), maxsplit=1)[0]
        status = next((s for s, rx in self.RULES if re.search(rx, first.lower())), "working")
        return clean(f"{status}: {first}")[:159]

    def warm(self, req: str) -> tuple[str, float, float | None]:
        t = time.perf_counter()
        out = self.summarize(req)
        return out, (time.perf_counter() - t) * 1000, None

    def cold(self, req: str) -> tuple[str, float]:
        t = time.perf_counter()
        r = subprocess.run([sys.executable, "-I", str(Path(__file__).resolve()), "--one-shot"], input=req,
                           capture_output=True, text=True, timeout=60)
        return clean(r.stdout), (time.perf_counter() - t) * 1000

    def close(self):
        pass


def _port_open(port: int) -> bool:
    with socket.socket() as s:
        s.settimeout(0.3)
        return s.connect_ex(("127.0.0.1", port)) == 0


def _http(url: str, body: dict | None = None, timeout: float = 120):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=timeout)


class Ollama:
    name = "ollama"

    def __init__(self, model: str | None):
        self.proc = None
        if not _port_open(11434):
            self.proc = subprocess.Popen([shutil.which("ollama"), "serve"], stdout=subprocess.DEVNULL,
                                         stderr=subprocess.DEVNULL)
            for _ in range(100):
                if _port_open(11434):
                    break
                time.sleep(0.1)
        tags = json.load(_http("http://127.0.0.1:11434/api/tags", timeout=10)).get("models", [])
        if model:
            tags = [t for t in tags if t["name"] == model]
        if not tags:
            raise RuntimeError("ollama has no installed model" + (f" named {model}" if model else ""))
        smallest = min(tags, key=lambda t: t.get("size", 1 << 62))
        self.model = smallest["name"]
        self.size = smallest.get("size")
        self.quant = (smallest.get("details") or {}).get("quantization_level")
        self.version = json.load(_http("http://127.0.0.1:11434/api/version", timeout=10)).get("version")

    def _gen(self, req: str, keep: str) -> tuple[str, float, float | None]:
        body = {"model": self.model, "prompt": req, "stream": True, "keep_alive": keep,
                "options": {"num_predict": MAX_TOKENS, "temperature": 0}}
        t = time.perf_counter()
        first = None
        out = []
        with _http("http://127.0.0.1:11434/api/generate", body) as r:
            for raw in r:
                ev = json.loads(raw)
                piece = ev.get("response", "")
                if piece and first is None:
                    first = (time.perf_counter() - t) * 1000
                out.append(piece)
                if "\n" in "".join(out).strip():
                    break  # one line is the answer; the rest is not waited for
                if ev.get("done"):
                    break
        return clean("".join(out)), (time.perf_counter() - t) * 1000, first

    def unload(self):
        try:
            _http("http://127.0.0.1:11434/api/generate", {"model": self.model, "keep_alive": 0}, timeout=30).read()
        except Exception:
            pass
        time.sleep(0.5)

    def warm(self, req):
        return self._gen(req, "10m")

    def cold(self, req):
        self.unload()
        out, ms, _ = self._gen(req, "10m")
        return out, ms

    def close(self):
        self.unload()
        if self.proc:
            self.proc.terminate()


def gguf_files() -> list[Path]:
    home = Path.home()
    roots = [home / "models", home / ".cache" / "huggingface", home / ".cache" / "lm-studio", home / ".lmstudio",
             home / "Library" / "Caches" / "llama.cpp", home / ".cache" / "llama.cpp"]
    found = []
    for root in roots:
        if root.is_dir():
            found += [Path(p) for p in glob.glob(str(root / "**" / "*.gguf"), recursive=True)]
    return sorted({p.resolve() for p in found if p.is_file()}, key=lambda p: p.stat().st_size)


class Llama:
    name = "llama.cpp"

    def __init__(self, model: str | None):
        files = gguf_files()
        if model:
            files = [f for f in files if model in str(f)]
        if not files:
            raise RuntimeError("no GGUF model installed")
        self.path = files[0]
        self.model = self.path.name
        self.size = self.path.stat().st_size
        self.quant = next((q for q in re.findall(r"(Q\d_\w+|F16|BF16|Q8_0)", self.model, re.I)), None)
        self.server = shutil.which("llama-server")
        self.cli = shutil.which("llama-cli")
        v = subprocess.run([self.server or self.cli, "--version"], capture_output=True, text=True, timeout=30)
        self.version = (v.stdout + v.stderr).strip().splitlines()[0] if (v.stdout + v.stderr).strip() else None
        self.proc = None
        self.port = 18435

    def _start(self):
        self.proc = subprocess.Popen([self.server, "-m", str(self.path), "--port", str(self.port), "-c", "2048",
                                      "--log-disable"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + 120
        while time.time() < deadline:
            try:
                if json.load(_http(f"http://127.0.0.1:{self.port}/health", timeout=2)).get("status") == "ok":
                    return
            except Exception:
                time.sleep(0.1)
        raise RuntimeError("llama-server did not come up in 120 s")

    def _complete(self, req):
        body = {"prompt": req, "n_predict": MAX_TOKENS, "temperature": 0, "stop": ["\n\n"], "stream": False}
        t = time.perf_counter()
        r = json.load(_http(f"http://127.0.0.1:{self.port}/completion", body))
        ms = (time.perf_counter() - t) * 1000
        first = (r.get("timings") or {}).get("prompt_ms")
        return clean(r.get("content", "")), ms, first

    def warm(self, req):
        if not self.server:
            raise RuntimeError("llama-cli only: no warm server path")
        if not self.proc:
            self._start()
        return self._complete(req)

    def cold(self, req):
        t = time.perf_counter()
        if self.server:
            self.close()
            self._start()
            out, _, _ = self._complete(req)
        else:
            r = subprocess.run([self.cli, "-m", str(self.path), "-n", str(MAX_TOKENS), "--temp", "0", "-no-cnv",
                                "-p", req], capture_output=True, text=True, timeout=120)
            out = clean(r.stdout[len(req):] if r.stdout.startswith(req) else r.stdout)
        return out, (time.perf_counter() - t) * 1000

    def close(self):
        if self.proc:
            self.proc.terminate()
            self.proc.wait(timeout=30)
            self.proc = None


def mlx_models() -> list[Path]:
    hub = Path(os.environ.get("HF_HOME", Path.home() / ".cache" / "huggingface")) / "hub"
    dirs = [Path(p) for p in glob.glob(str(hub / "models--mlx-community--*"))]

    def size(d: Path) -> int:
        return sum(f.stat().st_size for f in d.rglob("*") if f.is_file() and not f.is_symlink()) or \
            sum(f.resolve().stat().st_size for f in d.rglob("*.safetensors"))
    return sorted(dirs, key=size)


class Mlx:
    name = "mlx_lm"

    def __init__(self, model: str | None):
        import mlx_lm  # noqa: F401  (absent: the caller records why)
        dirs = mlx_models()
        if model:
            dirs = [d for d in dirs if model in d.name]
        if not dirs:
            raise RuntimeError("no mlx-community model in the Hugging Face cache")
        self.model = dirs[0].name.replace("models--", "").replace("--", "/")
        self.size = None
        self.quant = next(iter(re.findall(r"(\d+bit)", self.model)), None)
        self.version = getattr(mlx_lm, "__version__", None)
        self.loaded = None

    def warm(self, req):
        from mlx_lm import generate, load
        if not self.loaded:
            self.loaded = load(self.model)
        m, tok = self.loaded
        t = time.perf_counter()
        out = generate(m, tok, prompt=req, max_tokens=MAX_TOKENS, verbose=False)
        return clean(out), (time.perf_counter() - t) * 1000, None

    def cold(self, req):
        code = ("import sys;from mlx_lm import load,generate;m,t=load(sys.argv[1]);"
                f"print(generate(m,t,prompt=sys.stdin.read(),max_tokens={MAX_TOKENS},verbose=False))")
        t = time.perf_counter()
        r = subprocess.run([sys.executable, "-c", code, self.model], input=req, capture_output=True, text=True,
                           timeout=180)
        return clean(r.stdout), (time.perf_counter() - t) * 1000

    def close(self):
        self.loaded = None


def detect() -> dict:
    """What this machine has, read only: binaries, Python packages, model files."""
    have = {b: shutil.which(b) for b in ("ollama", "llama-server", "llama-cli", "mlx_lm.generate", "lms")}
    for mod in ("mlx", "mlx_lm", "llama_cpp", "transformers", "torch"):
        try:
            __import__(mod)
            have[f"py:{mod}"] = True
        except Exception:
            have[f"py:{mod}"] = False
    have["gguf"] = [f"{p} ({p.stat().st_size >> 20} MB)" for p in gguf_files()[:10]]
    have["mlx_models"] = [d.name for d in mlx_models()[:10]]
    have["ollama_api"] = _port_open(11434)
    return have


def open_runtime(kind: str, model: str | None, have: dict, why: list[str]):
    order = [kind] if kind != "auto" else ["ollama", "llama", "mlx"]
    for k in order:
        try:
            if k == "baseline":
                return Baseline()
            if k == "ollama" and (have["ollama"] or have["ollama_api"]):
                return Ollama(model)
            if k == "llama" and (have["llama-server"] or have["llama-cli"]):
                return Llama(model)
            if k == "mlx" and have["py:mlx_lm"]:
                return Mlx(model)
            why.append(f"{k}: not installed")
        except Exception as e:  # an installed runtime with no model, or one that would not start
            why.append(f"{k}: {type(e).__name__}: {e}")
    return None


# ---- the run -------------------------------------------------------------------------------------------------------

def p(values: list[float], q: float) -> float | None:
    if not values:
        return None
    s = sorted(values)
    return round(s[min(len(s) - 1, max(0, int(round(q * len(s) + 0.5)) - 1))], 3)


def measure(rt, cases: list[dict]) -> tuple[dict, list[dict]]:
    raw = []
    rt.warm(request(cases[0]))  # load once; the warm rows measure a loaded model
    for case in cases:
        req = request(case)
        warm = [rt.warm(req) for _ in range(WARM_ROUNDS)]
        out, cold_ms = rt.cold(req)
        line = warm[0][0]
        raw.append({"id": case["id"], "output": line, "cold_output": out,
                    "warm_ms": [round(w[1], 3) for w in warm], "first_token_ms": warm[0][2],
                    "cold_ms": round(cold_ms, 3), **score(case, line)})
    warm_all = [ms for r in raw for ms in r["warm_ms"]]
    cold_all = [r["cold_ms"] for r in raw]
    ft = [r["first_token_ms"] for r in raw if r["first_token_ms"] is not None]
    n_facts = sum(r["facts"] for r in raw)
    summary = {
        "cases": len(raw),
        "warm_p50_ms": p(warm_all, 0.5), "warm_p95_ms": p(warm_all, 0.95),
        "cold_p50_ms": p(cold_all, 0.5), "cold_p95_ms": p(cold_all, 0.95),
        "first_token_p95_ms": p(ft, 0.95),
        "max_chars": max(r["chars"] for r in raw),
        "status_accuracy": round(sum(r["status_ok"] for r in raw) / len(raw), 3),
        "key_fact_recall": round(sum(r["facts_hit"] for r in raw) / n_facts, 3) if n_facts else None,
        "unsupported": sum(r["unsupported"] for r in raw),
        "unsupported_rate": round(sum(r["unsupported"] for r in raw) / len(raw), 3),
    }
    return summary, raw


def verdict(s: dict) -> tuple[str, list[str]]:
    misses = []
    if s["warm_p95_ms"] is None or s["warm_p95_ms"] >= GATE["warm_p95_ms"]:
        misses.append(f"warm p95 {s['warm_p95_ms']} ms >= {GATE['warm_p95_ms']}")
    if s["cold_p95_ms"] is None or s["cold_p95_ms"] >= GATE["cold_p95_ms"]:
        misses.append(f"cold p95 {s['cold_p95_ms']} ms >= {GATE['cold_p95_ms']}")
    if s["max_chars"] >= GATE["max_chars"]:
        misses.append(f"longest output {s['max_chars']} chars >= {GATE['max_chars']}")
    if s["unsupported"] > GATE["unsupported"]:
        misses.append(f"{s['unsupported']} unsupported status claims")
    return ("pass" if not misses else "fail"), misses


def markdown(rep: dict) -> str:
    lines = [f"# Local summary gate: {rep['verdict']}", "",
             f"host {rep['host']['node']} ({rep['host']['machine']}, {rep['host']['system']}); "
             f"runtime {rep.get('runtime')} {rep.get('runtime_version')}; model {rep.get('model')} "
             f"quant {rep.get('quant')}", ""]
    for r in rep.get("rows", []):
        s = r["summary"]
        lines.append(f"- {r['runtime']} {r['model']}: warm p50/p95 {s['warm_p50_ms']}/{s['warm_p95_ms']} ms, cold "
                     f"p50/p95 {s['cold_p50_ms']}/{s['cold_p95_ms']} ms, first token p95 {s['first_token_p95_ms']} ms, "
                     f"max {s['max_chars']} chars, status {s['status_accuracy']}, recall {s['key_fact_recall']}, "
                     f"unsupported {s['unsupported']}/{s['cases']}")
    if rep.get("misses"):
        lines += ["", "misses: " + "; ".join(rep["misses"])]
    if rep.get("why_no_runtime"):
        lines += ["", "no runtime: " + "; ".join(rep["why_no_runtime"])]
    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--runtime", default="auto", choices=("auto", "baseline", "ollama", "llama", "mlx"))
    ap.add_argument("--model")
    ap.add_argument("--fixtures", type=Path, default=FIXTURES)
    ap.add_argument("--out", type=Path, default=Path(os.environ["FAST_CHECKS_OUT"]) if os.environ.get(
        "FAST_CHECKS_OUT") else None)
    ap.add_argument("--strict", action="store_true")
    ap.add_argument("--no-baseline", action="store_true", help="skip the baseline comparison row")
    ap.add_argument("--one-shot", action="store_true", help=argparse.SUPPRESS)
    a = ap.parse_args(argv)
    if a.one_shot:  # the baseline's cold path: one fresh process per request
        print(Baseline().summarize(sys.stdin.read()))
        return 0

    cases = load(a.fixtures)
    have = detect()
    rep = {"schema": "local-summary-gate/v1", "gate": GATE, "fixtures": str(a.fixtures.name),
           "fixture_ids": [c["id"] for c in cases], "warm_rounds": WARM_ROUNDS, "max_tokens": MAX_TOKENS,
           "host": {"node": platform.node(), "machine": platform.machine(), "system": platform.platform()},
           "detected": have, "rows": []}
    raws = []
    if not a.no_baseline and a.runtime != "baseline":
        b = Baseline()
        s, raw = measure(b, cases)
        rep["rows"].append({"runtime": "baseline", "model": b.model, "summary": s})
        raws += [{"runtime": "baseline", **r} for r in raw]
    why: list[str] = []
    rt = open_runtime(a.runtime, a.model, have, why)
    if rt is None:
        rep.update(verdict="no-runtime", why_no_runtime=why)
    else:
        try:
            s, raw = measure(rt, cases)
        finally:
            rt.close()
        v, misses = verdict(s)
        rep.update(verdict=v, misses=misses, runtime=rt.name, runtime_version=rt.version, model=rt.model,
                   quant=getattr(rt, "quant", None), model_bytes=getattr(rt, "size", None))
        rep["rows"].append({"runtime": rt.name, "model": rt.model, "summary": s})
        raws += [{"runtime": rt.name, **r} for r in raw]
    if a.out:
        a.out.mkdir(parents=True, exist_ok=True)
        (a.out / "report.json").write_text(json.dumps(rep, indent=1) + "\n", encoding="utf-8")
        (a.out / "raw.jsonl").write_text("".join(json.dumps(r) + "\n" for r in raws), encoding="utf-8")
        (a.out / "report.md").write_text(markdown(rep), encoding="utf-8")
    print(json.dumps(rep, indent=1))
    print(markdown(rep), file=sys.stderr)
    return 1 if a.strict and rep["verdict"] != "pass" else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
