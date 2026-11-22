#!/usr/bin/env python3
"""fixit-compile: a compile step that applies the compiler's own machine-applicable fix-its, then compiles again.

    fixit_compile.py run --kind cargo|tsc [--root DIR] [--out DIR] [--name NAME] [--keep] -- COMMAND...
    fixit_compile.py cargo-fixits FILE.jsonl [--root DIR]      the plan for saved `cargo --message-format=json` output
    fixit_compile.py tsc-errors FILE.log                        the TS errors a typecheck log holds, one JSON line each

Leo, 2026-11-19: "can the compile somehow be able to like not fail itself or whatever? Like, is there a way for us to
do that for like the more minor incidents, like the compilation itself to like fix itself?" This is ci-oops part 0a
(cmuxterm-hq tools/ci-oops, fixer id `fixit-compile`): class b, mechanical, inline in the compile step.

`run` runs COMMAND once, as the step always did (its exit code, its output). On a failure it reads the errors and asks
the compiler for each one's fix:
  cargo  the diagnostics of `--message-format=json` (added to a cargo check/build/test/clippy/rustc COMMAND; each
         message's rendered text is still printed): a suggestion counts only when every span of it is
         `MachineApplicable`, the applicability `cargo fix` and `clippy --fix` apply, and an error counts as fixable
         only when exactly one such suggestion answers it.
  tsc    the `error TSnnnn` lines of the log, then tsc-fixits.ts (beside this file) asks the TypeScript language
         service (getCodeFixesAtPosition) for each: fixable only when it offers exactly one fix, the fix is on the
         safe list there (no spelling guess, no @ts-ignore), and it carries no command.
Only when EVERY error is fixable (never a part, never a guess) are the edits applied and COMMAND run again. A green
second compile writes OUT/NAME.patch (the edits as a git diff against the tree that was compiled) and OUT/NAME.json
(what was fixed, the head it applies to) and prints the verdict line `CI_OOPS={json}` (class mechanical, fixer
fixit-compile) that ci-oops reads. The tree is then put back as it was (--keep leaves the fixed tree in place), and
`run` exits with COMMAND's first exit code either way: the commit under test does not compile, so its check stays
red; the fixup commit that .github/workflows/fixit-compile-push.yml pushes from the patch (a same-repo lane/* pull
request only) is the commit that goes green. When an error has no machine-applicable fix, or the second compile
fails too, nothing is written and the red is the real class's (a fix agent's, act_agent).

OUT defaults to $FIXIT_COMPILE_OUT, else $RUNNER_TEMP/fixit-compile, else .build/fixit-compile under --root. NAME
defaults to the kind and a hash of COMMAND, so two wrapped compiles in one job write two patches.
FIXIT_COMPILE=0 turns the fixing off (COMMAND runs alone, as before).
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXER = "fixit-compile"
CARGO_SUBCOMMANDS = ("check", "build", "test", "clippy", "rustc", "bench", "doc")
# rustc's own closing line: an error with no span that is not itself a compile error.
SUMMARY_ERROR = re.compile(r"^(aborting due to|could not compile|Some errors have detailed explanations|"
                           r"For more information about)")


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def git_root(path: Path) -> Path:
    try:
        out = subprocess.run(["git", "-C", str(path), "rev-parse", "--show-toplevel"], capture_output=True, text=True,
                             check=True).stdout.strip()
        return Path(out).resolve()
    except (OSError, subprocess.CalledProcessError):
        return path.resolve()


# ---- cargo ---------------------------------------------------------------------------------------------------------

def cargo_json_argv(argv: list[str]) -> list[str] | None:
    """COMMAND with `--message-format=json` added after cargo's subcommand (before a `--`), or None when COMMAND is not
    a cargo compile this can read (another program, an unknown subcommand, a non-JSON --message-format)."""
    if not argv or Path(argv[0]).name != "cargo":
        return None
    sub = next((i for i, a in enumerate(argv[1:], 1) if not a.startswith("-") and not a.startswith("+")), None)
    if sub is None or argv[sub] not in CARGO_SUBCOMMANDS:
        return None
    end = argv.index("--") if "--" in argv else len(argv)
    for i, arg in enumerate(argv[:end]):
        value = arg.split("=", 1)[1] if arg.startswith("--message-format=") else (
            argv[i + 1] if arg == "--message-format" and i + 1 < end else None)
        if value is not None:
            return argv if value.startswith("json") else None
    return argv[:sub + 1] + ["--message-format=json"] + argv[sub + 1:]


def _suggestions(diag: dict) -> list[list[dict]]:
    """Each suggestion of a rustc diagnostic: the spans with a replacement, the diagnostic's own and each child's
    (rustfix's reading: one child is one suggestion, its spans are applied together)."""
    found = []
    for node in [diag, *(diag.get("children") or [])]:
        spans = [s for s in node.get("spans") or [] if s.get("suggested_replacement") is not None]
        if spans:
            found.append(spans)
    return found


def resolve_source(file_name: str, roots: list[Path], repo: Path) -> Path | None:
    """A diagnostic's file under the repository (rustc names it relative to the workspace root it ran in), never a
    registry, a generated OUT_DIR or target/ file."""
    if not file_name or file_name.startswith("<"):
        return None
    candidates = [Path(file_name)] if Path(file_name).is_absolute() else [r / file_name for r in roots]
    for cand in candidates:
        try:
            real = cand.resolve()
        except OSError:
            continue
        if real.is_file() and real.is_relative_to(repo) and "target" not in real.relative_to(repo).parts:
            return real
    return None


def cargo_plan(messages: list[dict], roots: list[Path], repo: Path) -> dict:
    """{errors, fixable, unfixable: [why...], edits: {path: [(start, end, text)]}} for rustc's JSON diagnostics."""
    errors, unfixable, edits, seen = 0, [], {}, set()
    for msg in messages:
        diag = msg.get("message") if msg.get("reason") == "compiler-message" else msg
        if not isinstance(diag, dict) or not str(diag.get("level", "")).startswith("error"):
            continue
        text = str(diag.get("message") or "")
        if not diag.get("spans") and SUMMARY_ERROR.match(text):
            continue
        key = (text, json.dumps(diag.get("spans"), sort_keys=True))
        if key in seen:  # the same error from a lib and its test target
            continue
        seen.add(key)
        errors += 1
        first = (diag.get("rendered") or text).strip().splitlines()[0] if (diag.get("rendered") or text) else text
        machine = [s for s in _suggestions(diag)
                   if all(sp.get("suggestion_applicability") == "MachineApplicable" for sp in s)]
        if len(machine) != 1:
            unfixable.append(f"{first} ({'no machine-applicable fix' if not machine else 'more than one fix'})")
            continue
        planned = []
        for sp in machine[0]:
            path = resolve_source(sp.get("file_name", ""), roots, repo)
            if path is None:
                planned = None
                unfixable.append(f"{first} (the fix is outside this repository: {sp.get('file_name')})")
                break
            planned.append((path, int(sp["byte_start"]), int(sp["byte_end"]), sp["suggested_replacement"]))
        if planned is None:
            continue
        for path, start, end, replacement in planned:
            edits.setdefault(str(path), set()).add((start, end, replacement))
    return {"errors": errors, "fixable": errors - len(unfixable), "unfixable": unfixable,
            "edits": {p: sorted(v) for p, v in edits.items()}}


# ---- applying ------------------------------------------------------------------------------------------------------

def overlaps(edits: list[tuple[int, int, str]]) -> str | None:
    """Why EDITS (sorted, deduplicated) cannot all be applied, or None: two that touch the same bytes differently, or two
    insertions at one place (their order would be a guess)."""
    for (s1, e1, t1), (s2, e2, t2) in zip(edits, edits[1:]):
        if s2 < e1 or (s1 == s2 == e1 == e2):
            return f"two fixes overlap at byte {s2}"
    return None


def apply_edits(edits: dict[str, list[tuple[int, int, str]]], encoding_bytes: bool = True) -> dict[str, bytes]:
    """Apply each file's edits (byte offsets) back to front; returns the original bytes of each changed file."""
    originals = {}
    for path, file_edits in edits.items():
        data = Path(path).read_bytes()
        originals[path] = data
        for start, end, text in sorted(file_edits, reverse=True):
            if not 0 <= start <= end <= len(data):
                raise ValueError(f"{path}: fix span {start}..{end} is past the end of the file")
            data = data[:start] + text.encode() + data[end:]
        Path(path).write_bytes(data)
    return originals


def restore(originals: dict[str, bytes]) -> None:
    for path, data in originals.items():
        Path(path).write_bytes(data)


def diff_patch(repo: Path, paths: list[str]) -> str:
    rel = [str(Path(p).resolve().relative_to(repo)) for p in paths]
    return subprocess.run(["git", "-C", str(repo), "diff", "--binary", "--no-color", "--", *rel], capture_output=True,
                          text=True, check=True).stdout


# ---- running -------------------------------------------------------------------------------------------------------

def run_cargo(argv: list[str], cwd: Path, sink=None) -> tuple[int, list[dict]]:
    """COMMAND (already JSON) with each diagnostic's rendered text printed as cargo would; other stdout lines pass."""
    sink = sink or sys.stdout
    proc = subprocess.Popen(argv, cwd=cwd, stdout=subprocess.PIPE, text=True, errors="replace")
    messages = []
    assert proc.stdout is not None
    for line in proc.stdout:
        if line.startswith("{"):
            try:
                msg = json.loads(line)
            except ValueError:
                msg = None
            if isinstance(msg, dict) and "reason" in msg:
                if msg["reason"] == "compiler-message":
                    messages.append(msg)
                    rendered = (msg.get("message") or {}).get("rendered")
                    if rendered:
                        sink.write(rendered if rendered.endswith("\n") else rendered + "\n")
                        sink.flush()
                continue
        sink.write(line)
        sink.flush()
    return proc.wait(), messages


def run_plain(argv: list[str], cwd: Path, sink=None) -> tuple[int, str]:
    proc = subprocess.Popen(argv, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                            errors="replace")
    sink = sink or sys.stdout
    out = []
    assert proc.stdout is not None
    for line in proc.stdout:
        out.append(line)
        sink.write(line)
        sink.flush()
    return proc.wait(), "".join(out)


TSC_ERROR = re.compile(r"^(?P<file>[^\s(][^(:]*?)(?:\((?P<l1>\d+),(?P<c1>\d+)\)|:(?P<l2>\d+):(?P<c2>\d+))"
                       r"\s*(?::|-)\s*error\s+TS(?P<code>\d+):\s*(?P<msg>.*)$")
ANSI = re.compile(r"\x1b\[[0-9;]*m")


# `vp check`'s (Oxlint's) graphical report: `  x typescript(TS2339): message`, then `  ,-[path:line:col]` (or `╭─[`).
OXLINT_TS = re.compile(r"^[x×]\s+typescript\(TS(?P<code>\d+)\):\s*(?P<msg>.*)$")
OXLINT_AT = re.compile(r"^(?:,-|╭─)\[(?P<file>[^\]]+?):(?P<line>\d+):(?P<col>\d+)\]$")


def tsc_errors(log: str) -> list[dict]:
    """Every `file(line,col): error TSnnnn: ...` (or tsgo/pretty `file:line:col - error TSnnnn: ...`) line, and every
    `vp check` `x typescript(TSnnnn): ...` diagnostic with the `,-[file:line:col]` under it, once each."""
    found, seen, pending = [], set(), None
    for raw in log.splitlines():
        line = ANSI.sub("", raw).strip()
        line = re.sub(r"^\[[^\]]+\]\s*", "", line)  # a `[what]` prefix (fast-tier) or a vp task label
        header = OXLINT_TS.match(line)
        if header:
            pending = header
            continue
        at = OXLINT_AT.match(line) if pending is not None else None
        if at:
            err = {"file": at["file"].strip(), "line": int(at["line"]), "col": int(at["col"]),
                   "code": int(pending["code"]), "message": pending["msg"].strip()}
            pending = None
        else:
            m = TSC_ERROR.match(line)
            if not m:
                continue
            err = {"file": m["file"].strip(), "line": int(m["l1"] or m["l2"]), "col": int(m["c1"] or m["c2"]),
                   "code": int(m["code"]), "message": m["msg"].strip()}
        key = (err["file"], err["line"], err["col"], err["code"])
        if key not in seen:
            seen.add(key)
            found.append(err)
    return found


def tsc_plan(errors: list[dict], cwd: Path, repo: Path) -> dict:
    """Ask tsc-fixits.ts (the TypeScript language service of the project in CWD) for each error's one safe fix."""
    script = HERE / "tsc-fixits.ts"
    runner = os.environ.get("FIXIT_COMPILE_TS_RUNNER") or "bun"
    try:
        proc = subprocess.run([runner, str(script), "--project", str(cwd)], input=json.dumps(errors), cwd=cwd,
                              capture_output=True, text=True, timeout=600)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"errors": len(errors), "fixable": 0, "unfixable": [f"tsc-fixits did not run: {exc}"], "edits": {}}
    if proc.returncode != 0:
        tail = (proc.stderr or proc.stdout).strip().splitlines()[-3:]
        return {"errors": len(errors), "fixable": 0, "unfixable": [f"tsc-fixits failed: {' '.join(tail)}"],
                "edits": {}}
    try:
        plan = json.loads(proc.stdout)
    except ValueError:
        # A runner that exits 0 with no plan (a stand-in bun, a wrapper that ate the output) fixes nothing.
        return {"errors": len(errors), "fixable": 0, "unfixable": ["tsc-fixits printed no JSON plan"], "edits": {}}
    if not isinstance(plan, dict):
        return {"errors": len(errors), "fixable": 0, "unfixable": ["tsc-fixits printed no JSON plan"], "edits": {}}
    edits = {}
    for path, file_edits in (plan.get("edits") or {}).items():
        real = Path(path).resolve()
        if not real.is_relative_to(repo) or "node_modules" in real.parts:
            plan.setdefault("unfixable", []).append(f"a fix edits {path}, outside this repository's sources")
            continue
        data = real.read_bytes().decode("utf-8", errors="surrogateescape")
        # tsc-fixits gives UTF-16 offsets (the language service's); applying works in bytes.
        conv = _utf16_to_bytes(data)
        edits[str(real)] = sorted({(conv(s), conv(e), t) for s, e, t in file_edits})
    return {"errors": len(errors), "fixable": int(plan.get("fixable", 0)),
            "unfixable": list(plan.get("unfixable") or []), "edits": edits}


def _utf16_to_bytes(text: str):
    table, units, nbytes = {0: 0}, 0, 0
    for ch in text:
        units += 2 if ord(ch) > 0xFFFF else 1
        nbytes += len(ch.encode("utf-8", errors="surrogateescape"))
        table[units] = nbytes
    return lambda offset: table[offset]


def default_out(root: Path) -> Path:
    if os.environ.get("FIXIT_COMPILE_OUT"):
        return Path(os.environ["FIXIT_COMPILE_OUT"])
    if os.environ.get("RUNNER_TEMP"):
        return Path(os.environ["RUNNER_TEMP"]) / "fixit-compile"
    return root / ".build" / "fixit-compile"


# Where this tool's own lines and the second compile's output go: stdout, or --report FILE, so a caller that reads
# COMMAND's output as findings (fast_gate_webviews_checks.py) sees exactly what COMMAND alone printed.
REPORT = sys.stdout


def say(text: str) -> None:
    print(f"fixit-compile: {text}", file=REPORT, flush=True)


def summary(text: str) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        try:
            with open(path, "a") as fh:
                fh.write(text + "\n")
        except OSError:
            pass


def ctx_fields() -> dict:
    """What the ledger line and the push need to find this compile again."""
    env = os.environ
    return {k: v for k, v in {
        "repo": env.get("GITHUB_REPOSITORY"), "workflow": env.get("GITHUB_WORKFLOW"), "job": env.get("GITHUB_JOB"),
        "run_id": env.get("GITHUB_RUN_ID"), "run_attempt": env.get("GITHUB_RUN_ATTEMPT"),
        "head_sha": env.get("FIXIT_COMPILE_HEAD_SHA") or env.get("GITHUB_SHA"),
        "compiled_sha": env.get("GITHUB_SHA"), "head_ref": env.get("GITHUB_HEAD_REF") or None,
        "base_ref": env.get("GITHUB_BASE_REF") or None}.items() if v}


def run(args: argparse.Namespace) -> int:
    argv = list(args.command)
    if argv and argv[0] == "--":
        argv = argv[1:]
    if not argv:
        print("fixit_compile.py run: no COMMAND", file=sys.stderr)
        return 2
    cwd = Path.cwd()
    repo = Path(args.root).resolve() if args.root else git_root(cwd)
    enabled = os.environ.get("FIXIT_COMPILE", "1") != "0"
    red_at = now_iso()
    if args.kind == "cargo":
        json_argv = cargo_json_argv(argv) if enabled else None
        if json_argv is None:
            return run_plain(argv, cwd)[0]
        status, messages = run_cargo(json_argv, cwd)
    else:
        status, log = run_plain(argv, cwd)
    if status == 0 or not enabled:
        return status

    roots = [cwd, *[p for p in cwd.parents if p.is_relative_to(repo)]]
    if args.kind == "cargo":
        plan = cargo_plan(messages, roots, repo)
    else:
        errors = tsc_errors(log)
        plan = tsc_plan(errors, cwd, repo) if errors else {"errors": 0, "fixable": 0, "unfixable": [], "edits": {}}
    name = args.name or f"{args.kind}-{hashlib.sha256(' '.join(argv).encode()).hexdigest()[:10]}"
    if plan["errors"] == 0:
        say(f"exit {status} with no compiler error to fix; left as it is")
        return status
    edits = plan["edits"]
    why_not = plan["unfixable"] or ([o for o in (overlaps(v) for v in edits.values()) if o] if edits else [])
    if not why_not and not edits:
        why_not = ["no edit to apply"]
    if why_not:
        say(f"{plan['errors']} error(s), {plan['fixable']} with a machine-applicable fix: not every one, so nothing "
            f"is applied (the red is left for a fix agent)")
        for line in why_not[:10]:
            say(f"  left: {line}")
        return status

    say(f"every one of {plan['errors']} error(s) has a machine-applicable fix: applying {sum(map(len, edits.values()))}"
        f" edit(s) in {len(edits)} file(s), then compiling again")
    try:
        originals = apply_edits(edits)
    except (OSError, ValueError) as exc:
        say(f"could not apply the fixes ({exc}); left as it is")
        return status
    try:
        again = (run_plain(argv, cwd, REPORT) if args.kind != "cargo" else run_cargo(json_argv, cwd, REPORT))[0]
        if again != 0:
            say(f"the second compile failed too (exit {again}): the fixes are dropped, the first failure stands")
            restore(originals)
            return status
        patch = diff_patch(repo, list(edits))
    except Exception:
        restore(originals)
        raise
    if not args.keep:
        restore(originals)
    out = Path(args.out) if args.out else default_out(repo)
    out.mkdir(parents=True, exist_ok=True)
    (out / f"{name}.patch").write_text(patch)
    files = sorted(str(Path(p).relative_to(repo)) for p in edits)
    record = {"class": "mechanical", "rule": f"fixit-compile.{args.kind}", "fixer": FIXER, "swallow": True,
              "evidence": f"{plan['errors']} compile error(s), each with one machine-applicable fix",
              "errors": plan["errors"], "files": files, "patch": f"{name}.patch", "command": " ".join(argv),
              "red_at": red_at, "fixed_at": now_iso(), **ctx_fields()}
    (out / f"{name}.json").write_text(json.dumps(record, indent=2) + "\n")
    print("CI_OOPS=" + json.dumps(record, sort_keys=True, separators=(",", ":")), file=REPORT, flush=True)
    say(f"the second compile passed: {out / (name + '.patch')} ({len(files)} file(s)); the fixup commit carries it, "
        f"and this commit's check stays red (exit {status})")
    summary(f"### fixit-compile: {plan['errors']} {args.kind} error(s) fixed by the compiler's own fix-its\n\n"
            + "".join(f"- `{f}`\n" for f in files)
            + "\nThe fixup commit is pushed to a same-repo `lane/*` branch by fixit-compile-push; elsewhere apply "
              f"artifact `{name}.patch` with `git apply`.")
    return status


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_run = sub.add_parser("run")
    p_run.add_argument("--kind", choices=("cargo", "tsc"), required=True)
    p_run.add_argument("--root")
    p_run.add_argument("--out")
    p_run.add_argument("--name")
    p_run.add_argument("--keep", action="store_true")
    p_run.add_argument("--report", help="write this tool's lines and the second compile's output here, not stdout")
    p_run.add_argument("command", nargs=argparse.REMAINDER)
    p_plan = sub.add_parser("cargo-fixits")
    p_plan.add_argument("file")
    p_plan.add_argument("--root", default=".")
    p_tsc = sub.add_parser("tsc-errors")
    p_tsc.add_argument("file")
    args = parser.parse_args(argv)
    if args.cmd == "run":
        global REPORT
        if args.report:
            with open(args.report, "a") as report:
                REPORT = report
                try:
                    return run(args)
                finally:
                    REPORT = sys.stdout
        return run(args)
    if args.cmd == "cargo-fixits":
        root = Path(args.root).resolve()
        msgs = [json.loads(l) for l in Path(args.file).read_text().splitlines() if l.startswith("{")]
        plan = cargo_plan(msgs, [root], git_root(root))
        print(json.dumps(plan, indent=2, default=list))
        return 0
    for err in tsc_errors(Path(args.file).read_text(errors="replace")):
        print(json.dumps(err))
    return 0


if __name__ == "__main__":
    sys.exit(main())
