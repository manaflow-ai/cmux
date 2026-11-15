#!/usr/bin/env python3
"""The production Cloud journey plays the app's part on a warm spare (cloud-journey-prod.yml).

The lead: "The journey plays the app's part, like the MET harness: on spare.ready it copies the login through the
existing [transfer], the same as the app's SpareReady path. The login phase after the claim then drops to the
post-bind check. Use the account's existing credential in that workflow, with no new scope." and "The prod job's new
cargo build needs its own .github/warm-sources.json entry, like cloud-journey-prod.yml:preclaim (#42630), or the
warm-sources guard will go red."

Pinned here:
  - who may run each job: the production `journey` job only from main's own schedule or dispatch, never with the
    staging `preclaim` input; the staging `preclaim` job only on a dispatch of main or feat-cmux-next;
  - the journey job builds the shipped cmux-tui (warm from the rust cache) and passes it as --preclaim-login, never
    --cmux (the journey's exec and connect routes stay the API's);
  - the journey step gets no new secret: the account pair, the Claude token and nothing else;
  - the journey job's warm-sources entry names the rust cache it wires.
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "cloud-journey-prod.yml"
WARM = ROOT / ".github" / "warm-sources.json"

JOURNEY_IF = "github.repository_owner == 'manaflow-ai' && !inputs.preclaim && (github.event_name == 'schedule' || github.ref == 'refs/heads/main')"
PRECLAIM_IF = "github.repository_owner == 'manaflow-ai' && github.event_name == 'workflow_dispatch' && (github.ref == 'refs/heads/main' || github.ref == 'refs/heads/feat-cmux-next') && inputs.preclaim"


def jobs() -> dict:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]


def step(job: dict, *, id: str | None = None, uses: str | None = None, name: str | None = None) -> dict:
    for s in job["steps"]:
        if (id and s.get("id") == id) or (uses and str(s.get("uses", "")).startswith(uses)) or (name and s.get("name", "").startswith(name)):
            return s
    raise AssertionError(f"no step {id or uses or name}")


class ProdJourneyPreclaimLogin(unittest.TestCase):
    def test_job_conditions(self) -> None:
        self.assertEqual(jobs()["journey"]["if"], JOURNEY_IF)
        self.assertEqual(jobs()["preclaim"]["if"], PRECLAIM_IF)

    def test_journey_builds_cmux_tui_and_passes_it_as_preclaim_login(self) -> None:
        journey = jobs()["journey"]
        build = step(journey, id="build-cmux-tui")
        self.assertEqual(build["if"], "env.SELECTED == 'true'")
        self.assertIn("cargo build -p cmux-tui --bin cmux-tui --locked", build["run"])
        self.assertEqual(step(journey, uses="actions/checkout")["with"].get("submodules"), "recursive")
        cache = step(journey, uses="Swatinem/rust-cache")
        self.assertEqual(cache["with"]["workspaces"], "cmux-tui")
        self.assertIs(cache["with"]["cache-bin"], False)
        run = step(journey, id="journey")
        self.assertEqual(run["env"]["CMUX_TUI"], "${{ steps.build-cmux-tui.outputs.path }}")
        self.assertIn('--preclaim-login "$CMUX_TUI"', run["run"])
        self.assertNotIn("--cmux", run["run"])
        names = [s.get("id") or s.get("name") or s.get("uses") for s in journey["steps"]]
        self.assertLess(names.index("build-cmux-tui"), names.index("journey"))

    def test_journey_step_gets_no_new_secret(self) -> None:
        run = step(jobs()["journey"], id="journey")
        secrets = sorted(k for k, v in run["env"].items() if "secrets." in str(v))
        self.assertEqual(secrets, ["CLAUDE_CODE_OAUTH_TOKEN", "CMUX_DOGFOOD_STACK_EMAIL", "CMUX_DOGFOOD_STACK_PASSWORD"])
        self.assertEqual(jobs()["journey"]["environment"]["name"], "cmux-next-cloud-journey")
        self.assertEqual(jobs()["journey"]["permissions"], {"contents": "read", "issues": "write"})

    def test_warm_sources_entry(self) -> None:
        table = json.loads(WARM.read_text(encoding="utf-8"))["jobs"]
        self.assertEqual(table["cloud-journey-prod.yml:journey"], {"class": "linux-rust", "warm": ["actions-cache"]})
        self.assertIn("cloud-journey-prod.yml:preclaim", table)


if __name__ == "__main__":
    unittest.main()
