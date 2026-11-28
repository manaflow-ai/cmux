#!/usr/bin/env python3
"""Only ios-e2e.yml may join the tailnet through the ios-e2e Tailscale identity.

The federated identity behind `vars.TS_E2E_OIDC_CLIENT_ID` trusts only
`.github/workflows/ios-e2e.yml` under `workflow_dispatch` in the `ios-e2e`
environment (docs/ci/ios-e2e.md#secrets). In any other workflow file,
`tailscale/github-action` gets `token exchange failed with status 403:
Unauthorized` on every run, whatever runner it lands on. cmux-rd-windows.yml's
"Windows live host (tailnet)" did that on every feat-cmux-next landing from at
least 2026-11-19 (run 43840394161) to 11-28, a base red with no culprit PR.

So in a workflow other than ios-e2e.yml, a tailscale step that reads
TS_E2E_OIDC_CLIENT_ID must either fall back to it after its own identity
(`vars.OWN || vars.TS_E2E_OIDC_CLIENT_ID`) with `continue-on-error: true`, as
chief-evals.yml does, or not read it at all: give the workflow its own
identity and variables, and gate the job on them.

Run with workflow files as arguments to check only those files.
"""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
SHARED = "vars.TS_E2E_OIDC_CLIENT_ID"
OWNER = "ios-e2e.yml"


def problems(path: Path) -> list[str]:
    if path.name == OWNER:
        return []
    document = yaml.safe_load(path.read_text()) or {}
    found = []
    for name, job in (document.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        for step in job.get("steps") or []:
            if not isinstance(step, dict):
                continue
            if not str(step.get("uses", "")).startswith("tailscale/github-action@"):
                continue
            client = str((step.get("with") or {}).get("oauth-client-id", ""))
            if SHARED not in client:
                continue
            if step.get("continue-on-error") is True and "||" in client:
                continue
            found.append(
                f"{path.name}: job {name} joins with {SHARED}, the ios-e2e identity, which trusts "
                f"only {OWNER} (docs/ci/ios-e2e.md#secrets): its join is a 403 on every run. "
                "Give this workflow its own identity and variables and gate the job on them."
            )
    return found


class IdentityScope(unittest.TestCase):
    def test_workflows(self) -> None:
        paths = [Path(arg) for arg in sys.argv[1:]] or sorted(WORKFLOWS.glob("*.y*ml"))
        found = [line for path in paths for line in problems(path)]
        self.assertEqual(found, [], "\n".join(found))

    def test_detector_catches_the_cmux_rd_windows_shape(self) -> None:
        bad = """
jobs:
  live:
    steps:
      - uses: tailscale/github-action@abc
        with:
          oauth-client-id: ${{ vars.TS_E2E_OIDC_CLIENT_ID }}
          audience: ${{ vars.TS_E2E_OIDC_AUDIENCE }}
"""
        fallback = """
jobs:
  evals:
    steps:
      - uses: tailscale/github-action@abc
        continue-on-error: true
        with:
          oauth-client-id: ${{ vars.TS_OWN_OIDC_CLIENT_ID || vars.TS_E2E_OIDC_CLIENT_ID }}
          audience: ${{ vars.TS_OWN_OIDC_AUDIENCE || vars.TS_E2E_OIDC_AUDIENCE }}
"""
        with tempfile.TemporaryDirectory() as tmp:
            for name, text, expected in (
                ("other.yml", bad, 1),
                ("ios-e2e.yml", bad, 0),
                ("evals.yml", fallback, 0),
            ):
                path = Path(tmp) / name
                path.write_text(text)
                self.assertEqual(len(problems(path)), expected, name)


if __name__ == "__main__":
    unittest.main(argv=sys.argv[:1])
