"""risk evidence checks out .github/actions/app-token-spread only when the cmux-bot mint gave no token:
the checkout is the fallback mint's code, and running it on every grade was 4 s of a ~25 s job."""

from __future__ import annotations

import pathlib
import unittest

import yaml

WORKFLOW = pathlib.Path(__file__).resolve().parents[1] / ".github" / "workflows" / "risk-tier.yml"


class RiskTierSpreadLazyTest(unittest.TestCase):
    def test_spread_checkout_runs_only_after_an_empty_bot_mint(self) -> None:
        steps = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["evidence"]["steps"]
        names = [s.get("name") for s in steps]
        bot = names.index("Mint the cmux-bot read token")
        checkout = names.index("Check out the App token spread action")
        route = names.index("Mint the glaeda-route token")
        self.assertLess(bot, checkout)
        self.assertLess(checkout, route)
        self.assertIn("steps.glaeda-token-bot.outputs.token == ''", steps[checkout]["if"])
        self.assertIn("steps.glaeda-token-bot.outputs.token == ''", steps[route]["if"])
        self.assertTrue(steps[checkout].get("continue-on-error"))


if __name__ == "__main__":
    unittest.main()
