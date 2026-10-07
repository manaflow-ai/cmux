"""Source guards for the retired rollout gates and their UI entrypoints."""

from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RolloutRetirementTests(unittest.TestCase):
    def test_production_sources_do_not_read_the_upgrade_rollout_flag(self):
        forbidden = (
            "pro-upgrade-ui-enabled-release",
            "isProUpgradeUIEnabled",
            "proUpgradeUIEnabledRelease",
            "proUpgradeEnabled",
        )
        for folder, suffixes in (("Sources", {".swift"}), ("Packages", {".swift"}), ("web/app", {".ts", ".tsx"})):
            for path in (ROOT / folder).rglob("*"):
                if path.suffix not in suffixes or not path.is_file():
                    continue
                source = path.read_text()
                for token in forbidden:
                    with self.subTest(path=str(path.relative_to(ROOT)), token=token):
                        self.assertFalse(token in source, f"{path.relative_to(ROOT)} still reads the retired gate: {token}")

    def test_upgrade_badge_keeps_local_dismissal_and_shared_presenter(self):
        source = (ROOT / "Sources/ProBadgeStyle.swift").read_text()
        badge = source.split("struct ProBadgeView: View {", 1)[1].split("final class ProBadgeDebugWindowController", 1)[0]
        self.assertIn("if !ProBadgeStyleStore.shared.isDismissed", badge)
        self.assertIn("ProBadgeStyleStore.shared.isDismissed = true", badge)
        self.assertIn("ProUpgradePresenter.present(source: .sidebarBadge)", badge)
        self.assertNotIn("CmuxFeatureFlags", badge)

    def test_cloud_entrypoints_use_policy_and_local_activation(self):
        for relative in (
            "Sources/Cloud/CloudMachinesFeature+FeatureFlags.swift",
            "Sources/AppDelegate+CloudTunnel.swift",
            "Sources/Surfaces/CmuxTuiSurfaceProviderRegistry+Production.swift",
            "Packages/macOS/CmuxCloud/Sources/CmuxCloud/Environment/CloudActivationPolicy.swift",
        ):
            with self.subTest(path=relative):
                source = (ROOT / relative).read_text()
                self.assertNotIn("remoteEnabled", source)
                self.assertNotIn("cloudMachinesFlag", source)


if __name__ == "__main__":
    unittest.main()
