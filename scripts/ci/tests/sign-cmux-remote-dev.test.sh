#!/usr/bin/env bash
# Local contract test for the main-only Remote signer and its workflow route.
# This is intentionally not a GitHub job: codesign/ditto are macOS-only, while
# the checks below catch accidental credential-boundary and pin-shape changes
# on any checkout.
set -euo pipefail
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
signer="$scripts/ci/sign-cmux-remote-dev.sh"
workflow="$scripts/../.github/workflows/cmux-next-cua-helper-dev-sign.yml"

bash -n "$signer"
grep -Fq 'com.cmuxterm.remote.dev' "$signer"
grep -Fq 'Developer ID Application' "$signer"
grep -Fq 'TeamIdentifier=' "$signer"
grep -Fq 'libWebRTC.dylib' "$signer"
grep -Fq 'libcua_driver_sdk.dylib' "$signer"
if grep -Eq 'mapfile|readarray|-maxdepth|-quit' "$signer"; then
  echo "sign-cmux-remote-dev.sh must run on macOS Bash/find" >&2
  exit 1
fi
grep -Fq 'symlinks_marker=' "$signer"
grep -Fq 'frameworks_marker=' "$signer"
if grep -Eq 'find .*\| *head|find .*\| *grep' "$signer"; then
  echo "sign-cmux-remote-dev.sh must not use pipefail-sensitive find pipelines" >&2
  exit 1
fi
grep -Fq 'cua-helper-dev/{sha}/cmux-remote-dev-macos-arm64.zip' "$signer"
if grep -Fq 'Apple Development' "$signer"; then
  echo "sign-cmux-remote-dev.sh must reject Apple Development identities" >&2
  exit 1
fi

grep -Fq 'type: choice' "$workflow"
grep -Fq -- '- remote' "$workflow"
grep -Fq 'associated-prs.json' "$workflow"
grep -Fq 'source_pr: ${{ steps.resolve.outputs.source_pr }}' "$workflow"
grep -Fq 'source_pr="$pr_number"' "$workflow"
grep -Fq 'echo "source_pr=$source_pr"' "$workflow"
grep -Fq 'pull.get("state") == "open"' "$workflow"
grep -Fq 'base_repo.get("full_name") == repo' "$workflow"
grep -Fq 'base.get("ref") == "feat-cmux-next"' "$workflow"
grep -Fq 'head.get("sha") == sha' "$workflow"
grep -Fq 'head_repo.get("full_name") == repo' "$workflow"
grep -Fq 'pull-requests: read' "$workflow"
grep -Fq 'scripts/ci/sign-cmux-remote-dev.sh' "$workflow"
grep -Fq 'environment: release' "$workflow"
grep -Fq 'environment: cef-publish' "$workflow"
grep -Fq 'CMUX_CEF_R2_WRITE_ACCESS_KEY_ID' "$workflow"
grep -Fq 'cmux-remote-dev.pin.json' "$workflow"
grep -Fq 'cmux-next-helper-dev-signed' "$workflow"
grep -Fq 'product="cmux Remote"' "$workflow"

python3 - "$workflow" <<'PY'
import pathlib
import re
import sys

workflow = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
pin_job = workflow.split("\n  pin-pr:\n", 1)[1]
guard = re.search(r"\n    if: ([^\n]+)\n", pin_job)
assert guard and guard.group(1) == "needs.sdk.outputs.source_pr == ''"
assert "needs: [sdk, build, sign, publish]" in pin_job

def opens_pin_pr(source_pr):
    return source_pr == ""

assert opens_pin_pr("")
assert not opens_pin_pr("42365")
print("pin-pr guard fixtures: ancestor opens; unmerged source PR skips")
PY

# Execute the exact admission Python embedded in the workflow. This catches a
# future relaxation that merely keeps the contract strings while admitting a
# fork, stale head, closed PR or wrong base.
python3 - "$workflow" <<'PY'
import json
import pathlib
import subprocess
import sys
import tempfile
import textwrap

workflow = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
marker = 'python3 -I - "$RUNNER_TEMP/associated-prs.json" "$GH_REPO" "$sha" <<\'PY\''
start = workflow.index(marker) + len(marker)
snippet = workflow[start:].split("\n          PY\n", 1)[0]
snippet = textwrap.dedent(snippet.lstrip("\n"))
repo = "manaflow-ai/cmux"
sha = "a" * 40

def pull(*, state="open", base_ref="feat-cmux-next", head_sha=sha, head_repo=repo):
    return {
        "state": state,
        "number": 42365,
        "base": {"ref": base_ref, "repo": {"full_name": repo}},
        "head": {"sha": head_sha, "repo": {"full_name": head_repo}},
    }

cases = [
    ([pull()], "42365\n"),
    ([pull(head_repo="fork-user/cmux")], ""),
    ([pull(head_sha="b" * 40)], ""),
    ([pull(state="closed")], ""),
    ([pull(base_ref="main")], ""),
]
with tempfile.TemporaryDirectory() as directory:
    path = pathlib.Path(directory) / "pulls.json"
    for payload, expected in cases:
        path.write_text(json.dumps(payload), encoding="utf-8")
        result = subprocess.run(
            [sys.executable, "-", str(path), repo, sha],
            input=snippet,
            text=True,
            capture_output=True,
            check=False,
        )
        assert result.returncode == 0, result.stderr
        assert result.stdout == expected, (result.stdout, expected)
print("workflow admission fixtures: exact same-repo head accepted; fork/stale/closed/wrong-base rejected")
PY
echo "cmux Remote signing route contract: ok"
