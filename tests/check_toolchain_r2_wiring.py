"""Wiring checks for scripts/ci/toolchain-r2.sh (run by tests/test_ci_toolchain_r2.sh).

- Every "Restore pinned ..." step is followed directly by the setup-node (or scripts/ci/ensure-setup-node.sh) or setup-bun step it serves, for the
  same version, so the restore can never put one version down and the installer ask for another.
- Every Node or Bun version a restore step names (a literal) has a line in scripts/ci/toolchain-archives.sha256.
- Every exact-version setup step of the Freestyle-heavy workflows has its restore step.
- The Rust action restores before it installs; the seed workflow seeds every pin.
"""
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
pins = (ROOT / "scripts/ci/toolchain-archives.sha256").read_text()
errors = []
restored = {}
RUN = re.compile(r"toolchain-r2\.sh\"? restore (node|bun) (\S+) \|\| true")
for path in sorted((ROOT / ".github/workflows").glob("*.yml")):
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    for job, body in (data.get("jobs") or {}).items():
        steps = body.get("steps") or []
        for index, step in enumerate(steps):
            m = RUN.search(str(step.get("run", "")))
            if not m:
                continue
            kind, version = m.groups()
            nxt = steps[index + 1] if index + 1 < len(steps) else {}
            action = {"node": "actions/setup-node@", "bun": "oven-sh/setup-bun@"}[kind]
            key = {"node": "node-version", "bun": "bun-version"}[kind]
            where = f"{path.name}:{job}:{index}"
            # scripts/ci/ensure-setup-node.sh VERSION reads the same RUNNER_TOOL_CACHE/node/VERSION/ARCH.
            ensure = re.search(r"ensure-setup-node\.sh\s+(\S+)", str(nxt.get("run", ""))) if kind == "node" else None
            if action not in str(nxt.get("uses", "")) and not ensure:
                errors.append(f"{where}: the restore step is not followed by {action} or ensure-setup-node.sh")
                continue
            have = ensure.group(1) if ensure else str((nxt.get("with") or {}).get(key, "")).strip()
            if have != version.strip("'\""):
                errors.append(f"{where}: restores {kind} {version} but the next step sets up {have}")
            if re.fullmatch(r"\d+\.\d+\.\d+", version):
                name = f"node-v{version}-linux-x64.tar.gz" if kind == "node" else f"bun-v{version}-linux-x64.zip"
                if name not in pins:
                    errors.append(f"{where}: no pin for {name} in toolchain-archives.sha256")
            restored[(path.name, job)] = restored.get((path.name, job), 0) + 1
for wanted in (("ci-web.yml", None), ("cmux-next-pr-autofix.yml", "repair"), ("cmux-next.yml", None)):
    if not any(w == wanted[0] and (wanted[1] is None or j == wanted[1]) for (w, j) in restored):
        errors.append(f"no restore step in {wanted}")

rust = (ROOT / ".github/actions/setup-cmux-tui-rust/action.yml").read_text()
if not (0 <= rust.find("toolchain-r2.sh") < rust.find("Ensure rustup is available") < rust.find("Install pinned Rust toolchain")):
    errors.append("setup-cmux-tui-rust does not restore the toolchain before it ensures rustup and installs")
if "toolchain-r2.sh seed all" not in (ROOT / ".github/workflows/cmux-next-fast-tier-seed.yml").read_text():
    errors.append("nothing seeds the toolchains")
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"{sum(restored.values())} restore steps wired")
