"""Every actions/create-github-app-token step names only inputs the action declares, and at least one permission.

The class (cmuxterm-hq docs/handbook/app-token-input-the-action-ignores.md): the runner drops a `with:` input the
action does not declare, with only a warning in the log, and create-github-app-token mints a token with every
permission of the App's installation when no `permission-*` input reaches it. In cmuxterm-hq a "read-only" variables
token (`permission-actions-variables: read`, an input v3.2.0 lacks) carried the whole installation (Codex review of
hq#9110, F4), and one workflow pinned a sha of the action that does not exist.

DECLARED is the action's inputs at the one pinned sha, from its action.yml (v3.2.0); a new pin needs its list here.
WHOLE_INSTALLATION names the steps that mint with no permission today because they need Actions variables, which the
action cannot ask for; each must still exist, and no new step may join without a line here saying why.
"""
from __future__ import annotations

from pathlib import Path
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
ACTION = "actions/create-github-app-token"
PERMISSIONS_V3_2_0 = (
    "actions administration artifact-metadata attestations checks codespaces contents "
    "custom-properties-for-organizations dependabot-secrets deployments discussions email-addresses "
    "enterprise-custom-properties-for-organizations environments followers git-ssh-keys gpg-keys interaction-limits "
    "issues members merge-queues metadata organization-administration organization-announcement-banners "
    "organization-copilot-seat-management organization-custom-org-roles organization-custom-properties "
    "organization-custom-roles organization-events organization-hooks organization-packages "
    "organization-personal-access-token-requests organization-personal-access-tokens organization-plan "
    "organization-projects organization-secrets organization-self-hosted-runners organization-user-blocking packages "
    "pages profile pull-requests repository-custom-properties repository-hooks repository-projects "
    "secret-scanning-alerts secrets security-events single-file starring statuses team-discussions "
    "vulnerability-alerts workflows").split()
DECLARED = {
    "bcd2ba49218906704ab6c1aa796996da409d3eb1": frozenset(
        ["client-id", "app-id", "private-key", "owner", "repositories", "enterprise", "skip-token-revoke",
         "github-api-url"] + [f"permission-{p}" for p in PERMISSIONS_V3_2_0]),
}
# (workflow, step name): why it names no permission. All three read or write a repository variable.
WHOLE_INSTALLATION = {
    ("nightly.yml", "Mint release App token", "writer-token"): "reads NIGHTLY_NEXT_WRITER live before publishing",
    ("nightly.yml", "Mint the release App token that reads the Dev ring switch", "ring-token"):
        "reads the Dev ring switch variable",
    ("ci-cloud-overflow-probe.yml", "Mint the switch token", "switch-token"): "writes RUNNER_POOLS",
}


def app_token_steps(doc):
    if isinstance(doc, dict):
        uses = doc.get("uses")
        if isinstance(uses, str) and uses.startswith(ACTION + "@"):
            yield doc
        for value in doc.values():
            yield from app_token_steps(value)
    elif isinstance(doc, list):
        for value in doc:
            yield from app_token_steps(value)


def problems(name: str, doc, allowed=frozenset()) -> tuple[list[str], set]:
    out, excused = [], set()
    for step in app_token_steps(doc):
        label = f"{name}: {step.get('name') or step.get('id') or ACTION}"
        sha = step["uses"].split("@", 1)[1].split()[0]
        declared = DECLARED.get(sha)
        if declared is None:
            out.append(f"{label}: pinned to {sha}, not a sha whose inputs this test lists ({', '.join(DECLARED)})")
            continue
        given = set((step.get("with") or {}).keys())
        for key in sorted(given - declared):
            out.append(f"{label}: `{key}` is not an input of {ACTION}; the runner drops it and the token gets more "
                       "than asked")
        if not any(k.startswith("permission-") and k in declared for k in given):
            key = (name, step.get("name"), step.get("id"))
            if key in allowed:
                excused.add(key)
            else:
                out.append(f"{label}: names no permission, so the token carries the App's whole installation")
    return out, excused


class EveryStep(unittest.TestCase):
    def test_every_workflow_names_only_declared_inputs_and_some_permission(self):
        found, excused = [], set()
        for path in sorted(WORKFLOWS.glob("*.y*ml")):
            more, ok = problems(path.name, yaml.safe_load(path.read_text(encoding="utf-8")), WHOLE_INSTALLATION)
            found += more
            excused |= ok
        self.assertEqual(found, [])
        # An exception whose step was fixed or renamed comes off the list.
        self.assertEqual(excused, set(WHOLE_INSTALLATION))

    def test_the_detector_catches_the_three_shapes(self):
        sha = next(iter(DECLARED))
        doc = {"jobs": {"a": {"steps": [
            {"name": "vars", "uses": f"{ACTION}@{sha}", "with": {"app-id": 1, "permission-actions-variables": "read"}},
            {"name": "none", "uses": f"{ACTION}@{sha}", "with": {"app-id": 1, "repositories": "x"}},
            {"name": "typo", "uses": f"{ACTION}@bcd2ba49218906704ec6b1aa796996da409d3eb1",
             "with": {"permission-actions": "read"}},
            {"name": "fine", "uses": f"{ACTION}@{sha}", "with": {"app-id": 1, "permission-actions": "read"}}]}}}
        got, _ = problems("w.yml", doc)
        self.assertEqual(len(got), 4, got)  # vars: undeclared input and no permission; none; typo
        self.assertTrue(any("`permission-actions-variables` is not an input" in p for p in got))
        self.assertTrue(any("w.yml: none: names no permission" in p for p in got))
        self.assertTrue(any("w.yml: typo: pinned to bcd2ba49218906704ec6b1aa" in p for p in got))


if __name__ == "__main__":
    unittest.main()
