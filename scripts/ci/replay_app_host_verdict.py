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
import sys
from pathlib import Path


def load_accounting(path: Path):
    spec = importlib.util.spec_from_file_location("acct_under_test", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules["acct_under_test"] = module
    spec.loader.exec_module(module)
    return module


def selectors_from_meta(meta: Path) -> list[str]:
    """Recover the batch's -only-testing selectors from its recorded argv."""
    out = []
    for line in meta.read_text(encoding="utf-8").splitlines():
        if not line.startswith("arg="):
            continue
        value = line[4:].strip().strip("'")
        if value.startswith("-only-testing:"):
            out.append(value.split("-only-testing:", 1)[1])
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--artifacts", required=True, type=Path)
    ap.add_argument("--shard", required=True)
    ap.add_argument("--repo", required=True, type=Path, help="a cmux checkout")
    ap.add_argument("--accounting", type=Path, help="override the module under test")
    ap.add_argument("--xcode-status", type=int, default=65)
    args = ap.parse_args()

    acct = load_accounting(
        args.accounting or args.repo / "scripts/ci/app_host_result_accounting.py"
    )
    shard_dir = args.artifacts / f"shard{args.shard}"
    inventory_files = list((args.artifacts / "inventory").glob("*test-inventory*.json"))
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
        sel_file = shard_dir / f".{tag}.selectors"
        sel_file.write_text("\n".join(selectors) + "\n", encoding="utf-8")
        results = acct.merge_result_files([tests_json[0]])
        passed, messages = acct.check_run(
            inventory=inventory,
            selectors=acct.load_selectors(sel_file),
            results=results,
            known=known,
            log_text=log[0].read_text(encoding="utf-8", errors="replace"),
            xcode_status=args.xcode_status,
        )
        new = [m for m in messages if m.startswith("RATCHET_NEW_FAILURE")]
        total_new += len(new)
        print(f"\n=== {tag}  selectors={len(selectors)} typed={len(results)} passed={passed}")
        for m in messages:
            print("   ", m)
    print(f"\ntotal RATCHET_NEW_FAILURE across shard {args.shard}: {total_new}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
