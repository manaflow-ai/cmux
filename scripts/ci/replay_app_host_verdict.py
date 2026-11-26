#!/usr/bin/env python3
"""Replay app-host shard verdicts offline from a CI run's artifacts.

Answers "what would this shard have reported?" without a Mac or a CI round
trip -- including which selected tests never produced a terminal result, which
the shard's own output may omit entirely.

Usage:
  # once per run+shard (downloads ~100-300 MB; keep off /tmp, it is a tmpfs)
  gh run download <RUN_ID> --repo manaflow-ai/cmux \
      -n cmux-app-host-diagnostics-shard-<N>-run-1 -D <DIR>/shard<N>
  gh run download <RUN_ID> --repo manaflow-ai/cmux \
      -n cmux-app-host-test-inventory-<RUN_ID>-1 -D <DIR>/inventory

  python3 replay_app_host_verdict.py --artifacts <DIR> --shard <N> --repo <CHECKOUT>
  python3 replay_app_host_verdict.py --artifacts <DIR> --shard <N> --repo <CHECKOUT> \
      --accounting <OTHER_CHECKOUT>/scripts/ci/app_host_result_accounting.py
"""
import argparse
import importlib.util
import shlex
import sys
import tempfile
from pathlib import Path


def load_accounting(path: Path):
    spec = importlib.util.spec_from_file_location("acct_under_test", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules["acct_under_test"] = module
    spec.loader.exec_module(module)
    return module


def selectors_from_meta(meta: Path) -> list[str]:
    """Recover the batch's -only-testing selectors from its recorded argv.

    run-app-host-xcodebuild.sh writes these with `printf 'arg=%q\\n'`, so the
    value is shell-quoted. Since #13831 gave Swift Testing selectors their
    trailing parens, %q escapes them -- `testFoo\\(\\)` -- and a selector read
    literally matches nothing in the inventory. Unquote with shlex rather than
    stripping one quote character.
    """
    out = []
    for line in meta.read_text(encoding="utf-8").splitlines():
        if not line.startswith("arg="):
            continue
        raw = line[4:].strip()
        # %q falls back to ANSI-C $'...' when the value holds a non-printable
        # character. shlex does not decode that form and does not raise on it:
        # it yields a leading '$' and a literal backslash escape, which fails
        # the prefix test below and drops the selector silently. Unreachable
        # for today's identifiers, but a silently shorter selector set is the
        # exact failure this tool exists to expose, so refuse it.
        if raw.startswith("$'"):
            raise SystemExit(
                f"{meta.name}: ANSI-C quoted argv is not decodable here: {line!r}"
            )
        try:
            fields = shlex.split(raw)
        except ValueError:
            # An unbalanced quote means this line is not recoverable; skipping
            # it would silently shrink the selector set, so fail loudly.
            raise SystemExit(f"{meta.name}: cannot unquote argv line: {line!r}")
        if not fields:
            continue
        if len(fields) > 1:
            # %q output is one token by construction, so more than one means
            # the recorded argv is not what this parser assumes.
            raise SystemExit(
                f"{meta.name}: argv line split into {len(fields)} tokens: {line!r}"
            )
        value = fields[0]
        if value.startswith("-only-testing:"):
            out.append(value.split("-only-testing:", 1)[1])
    return out


def xcode_status_from_log(log_text: str) -> int:
    """Recover the batch's exit status from xcodebuild's own closing banner.

    The .meta does not record it, and check_run treats it as evidence: a batch
    that really exited 0 replayed as 65 reports "xcodebuild exited 65 without a
    typed failed Test Case", a contradiction that never happened.
    """
    if "** TEST SUCCEEDED **" in log_text:
        return 0
    return 65


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--artifacts", required=True, type=Path)
    ap.add_argument("--shard", required=True)
    ap.add_argument("--repo", required=True, type=Path, help="a cmux checkout")
    ap.add_argument("--accounting", type=Path, help="override the module under test")
    ap.add_argument(
        "--xcode-status",
        type=int,
        default=None,
        help="override; by default each batch's status comes from its own log",
    )
    args = ap.parse_args()

    acct = load_accounting(
        args.accounting or args.repo / "scripts/ci/app_host_result_accounting.py"
    )
    shard_dir = args.artifacts / f"shard{args.shard}"
    inventory_files = sorted((args.artifacts / "inventory").glob("*test-inventory*.json"))
    if not inventory_files:
        print("no inventory artifact under --artifacts/inventory", file=sys.stderr)
        return 2
    inventory = acct.load_inventory(inventory_files[0])
    known = acct.load_catalog(args.repo / "scripts/ci/app-host-known-failures.json")

    metas = sorted(shard_dir.glob(f"captures/*unit-physical-{args.shard}-logical-*.meta"))
    if not metas:
        print(f"no unit batches in {shard_dir}/captures", file=sys.stderr)
        return 2

    total_new = 0
    for meta in metas:
        tag = meta.name.replace("cmux-app-host-xcodebuild-", "").split("-pid-")[0]
        tests_json = sorted(shard_dir.glob(f"xcresults/*{tag}*.tests.json"))
        log = sorted(shard_dir.glob(f"captures/*{tag}*.log"))
        if not tests_json or not log:
            print(f"{tag}: missing typed results or log, skipped")
            continue
        selectors = selectors_from_meta(meta)
        if not selectors:
            print(f"{tag}: no -only-testing selectors in argv, skipped")
            continue
        # Write the selector file outside the artifact tree: these downloads are
        # 100-300 MB and get reused across --accounting runs, so a replay should
        # not mutate its own input.
        with tempfile.NamedTemporaryFile(
            "w", suffix=".selectors", encoding="utf-8"
        ) as sel_file:
            sel_file.write("\n".join(selectors) + "\n")
            sel_file.flush()
            loaded = acct.load_selectors(Path(sel_file.name))
        results = acct.merge_result_files([tests_json[0]])
        log_text = log[0].read_text(encoding="utf-8", errors="replace")
        status = (
            args.xcode_status
            if args.xcode_status is not None
            else xcode_status_from_log(log_text)
        )
        passed, messages = acct.check_run(
            inventory=inventory,
            selectors=loaded,
            results=results,
            known=known,
            log_text=log_text,
            xcode_status=status,
        )
        new = [m for m in messages if m.startswith("RATCHET_NEW_FAILURE")]
        total_new += len(new)
        print(
            f"\n=== {tag}  selectors={len(selectors)} typed={len(results)} "
            f"status={status} passed={passed}"
        )
        for m in messages:
            print("   ", m)
    print(f"\ntotal RATCHET_NEW_FAILURE across shard {args.shard}: {total_new}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
