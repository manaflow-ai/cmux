"""risk_tier.py grades a pull request low, normal or high, and holds only high (for a person) and takebacks."""
import importlib.util
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("risk_tier", ROOT / "scripts/ci/risk_tier.py")
risk = importlib.util.module_from_spec(spec)
sys.modules["risk_tier"] = risk  # dataclasses looks the module up by name
spec.loader.exec_module(risk)

NEXT = "Packages/macOS/CmuxNext/Sources/"
HEAD = "0123456789abcdef0123456789abcdef01234567"


class ClassifyTests(unittest.TestCase):
    def tier(self, *files, patches=None):
        return risk.classify(list(files), patches).tier

    def test_docs_copy_generated_tests_and_tooling_are_low(self):
        self.assertEqual(self.tier("docs/ci/merge-main.md", "skills/cmux-testing/SKILL.md"), "low")
        self.assertEqual(self.tier(NEXT.replace("Sources", "Tests") + "CmuxNextSidebarTests/RowTests.swift"), "low")
        self.assertEqual(self.tier("cmux-tui/crates/acpmux/tests/hub_integration/offers.rs"), "low")
        self.assertEqual(self.tier(NEXT + "CmuxNextApp/Localizable.xcstrings"), "low")
        self.assertEqual(self.tier("schemas/settings-export/cmux-next.json.sha256"), "low")
        self.assertEqual(self.tier(".claude/settings.json", "tools/x.py"), "low")

    def test_most_app_ui_logic_and_ci_is_normal(self):
        for path in (
            NEXT + "CmuxNextSidebar/SidebarRow.swift",
            "webviews/src/agent-pane/Composer.tsx",
            "webviews/src/agent-session/acpmux/styles.css",
            NEXT + "CmuxNextErrorJournal/ErrorJournal.swift",
            NEXT + "CmuxNextDaemon/DaemonClient.swift",
            NEXT + "CmuxNextTerminal/TerminalInput.swift",
            "cmux-tui/crates/acpmux/src/deliver.rs",
            "cmux-tui/spec/resource-operations-v2.json",
            "schemas/defaults/cmux-next.json",
            "Packages/macOS/CmuxNext/Package.resolved",
            "ghostty",
            ".github/workflows/cmux-next.yml",
            ".github/workflows/ci.yml",
            "scripts/ci/health_report.py",
            "brand-new-dir/thing.swift",
        ):
            with self.subTest(path=path):
                self.assertEqual(self.tier(path), "normal")

    def test_size_alone_never_raises_the_tier(self):
        path = NEXT + "CmuxNextSidebar/A.swift"
        patch = "\n".join(f"+let line{i} = {i}" for i in range(5000))
        self.assertEqual(self.tier(path, patches={path: patch}), "normal")

    def test_auth_relay_policy_migrations_release_and_the_gate_are_high_at_any_size(self):
        for path in (
            "Packages/Shared/CmuxAuthRuntime/Sources/CmuxAuthRuntime/TokenStores/FileStackTokenStore.swift",
            "Packages/Shared/CMUXAuthCore/Sources/CMUXAuthCore/Models/Session.swift",
            NEXT + "CmuxNextApp/WebAuth/WebAuthSession.swift",
            NEXT + "CmuxNextPopups/WebAuth/WebAuthSessionBroker.swift",
            "web/services/auth/hexclave/verify.ts",
            "cmux.nightly.entitlements",
            NEXT + "CmuxNextControl/ControlAuthorizer.swift",
            NEXT + "CmuxNextControl/ControlPeerAncestry.swift",
            "cmux-tui/crates/chatmux-relay/src/lib.rs",
            "cmux-tui/relays/cloudflare-do/src/index.ts",
            "web/services/relay/forward.ts",
            "web/db/migrations/20260707032007_same_quicksilver/migration.sql",
            "backend/db/drizzle/0042_add.sql",
            "migrations/0001_init.sql",
            NEXT + "CmuxNextSettings/SettingsMigration.swift",
            "web/convex/schema.ts",
            ".github/workflows/release.yml",
            ".github/workflows/nightly-next.yml",
            "scripts/sign-cmux-bundle-helpers.sh",
            "scripts/ci/notarize-nightly-dmg.sh",
            ".github/workflows/sdk-publish-crates.yml",
            NEXT + "CmuxNextUpdater/UpdateDriver.swift",
            ".github/CODEOWNERS",
            ".github/workflows/risk-tier.yml",
            "scripts/ci/risk_tier.py",
        ):
            with self.subTest(path=path):
                self.assertEqual(self.tier(path), "high")

    def test_everything_that_enforces_risk_evidence_is_the_gate(self):
        # gh-merge-green and next-autoland are what refuse a red `risk evidence`; a normal pull
        # request could otherwise drop that refusal with no person looking.
        for path in ("scripts/gh-merge-green", "scripts/ci/next_batch.py", ".github/workflows/risk-tier-tests.yml",
                     "scripts/ci/risk_tier.py", ".github/workflows/risk-tier.yml", ".github/CODEOWNERS"):
            with self.subTest(path=path):
                self.assertEqual(risk.classify_path(path), ("high", "the risk gate itself"))

    def test_docs_copy_and_logs_are_low_even_in_a_high_directory(self):
        for path in (
            "docs/vm-identity-edge-auth.md", "docs/remote-tmux-reconnect-auth-acceptance.md",
            "cmux-tui/docs/chatgpt-auth-refresh-remote-lifecycle.md",
            "release-notes/next/highlights/browser-sign-in-and-certificate-warning.md",
            NEXT + "CmuxNextUpdater/Resources/Localizable.xcstrings",
            "services/iroh-relay-minter/README.md", "services/iroh-relay-minter/LICENSE",
            "docs/iroh-v2/evidence/run-1/iroh-v2-auth-test.log",
        ):
            with self.subTest(path=path):
                self.assertEqual(self.tier(path), "low")

    def test_a_delete_moved_out_of_a_test_or_doc_is_still_new_in_product_code(self):
        # The test-cleanup idiom moved into product code is how a new delete reaches users.
        src = NEXT + "CmuxNextHistory/HistoryStore.swift"
        line = "try? FileManager.default.removeItem(at: url)"
        for other in ("Packages/macOS/CmuxNext/Tests/X/HistoryTests.swift", "docs/history.md", "scripts/clean.py"):
            with self.subTest(other=other):
                self.assertEqual(self.tier(src, other, patches={src: "+    " + line, other: "-    " + line}), "high")

    def test_lockfiles_are_normal_even_in_a_high_directory(self):
        for path in ("Cargo.lock", "web/package-lock.json", "bun.lock",
                     "services/iroh-relay-minter/Cargo.lock", "web/services/auth/package-lock.json"):
            with self.subTest(path=path):
                self.assertEqual(self.tier(path), "normal")

    def test_the_batch_lander_workflow_is_the_gate(self):
        self.assertEqual(risk.classify_path(".github/workflows/cmux-next-batch.yml"), ("high", "the risk gate itself"))

    def test_a_top_level_migration_is_high(self):
        self.assertEqual(risk.classify_path("migrations/0002_sessions.sql")[0], "high")

    def test_rust_and_drizzle_deletes_count(self):
        rs = "cmux-tui/crates/cmux-tui-core/src/history.rs"
        for line in ("+    std::fs::remove_file(&path)?;", "+    fs::remove_dir(&dir)?;"):
            with self.subTest(line=line):
                self.assertEqual(self.tier(rs, patches={rs: line}), "high")
        ts = "web/services/sessions/cleanup.ts"
        for line in ("+  await db.delete(sessions).where(eq(sessions.id, id));",
                     "+  await tx.delete(sessions).where(eq(sessions.id, id));"):
            with self.subTest(line=line):
                self.assertEqual(self.tier(ts, patches={ts: line}), "high")

    def test_an_edited_or_moved_delete_is_not_new(self):
        path = "backend/apps/api/src/cleanup.ts"
        edited = "-  await db.execute(`DELETE FROM sessions WHERE id = $1`)\n+  await db.execute(`DELETE FROM sessions WHERE id = $1 AND owner = $2`)"
        self.assertEqual(self.tier(path, patches={path: edited}), "normal")
        other = "backend/apps/api/src/sessions.ts"
        moved = {path: "-  await db.execute(`DELETE FROM sessions WHERE id = $1`)",
                 other: "+  await db.execute(`DELETE FROM sessions WHERE id = $1`)"}
        self.assertEqual(self.tier(path, other, patches=moved), "normal")
        # Moving one delete out and writing a new one in its place is a new delete.
        swapped = {path: "-  await db.execute(`DELETE FROM sessions WHERE id = $1`)\n+  await db.execute(`DELETE FROM tokens`)",
                   other: "+  await db.execute(`DELETE FROM sessions WHERE id = $1`)"}
        self.assertEqual(self.tier(path, other, patches=swapped), "high")
        # One kept, one new: still a new delete.
        grown = edited + "\n+  await db.execute(`DELETE FROM tokens WHERE id = $1`)"
        self.assertEqual(self.tier(path, patches={path: grown}), "high")

    def test_in_memory_purges_nested_scripts_bindings_and_block_comments_are_not_deletes(self):
        cases = {
            "cmux-tui/crates/cmux-tui-core/src/surface.rs": "+        self.purge_surface_side_tables(id);",
            "webviews/src/agent-pane/session.ts": "+  return purgedSession(state);",
            "cmux-tui/scripts/bench-terminal-perf.py": "+    shutil.rmtree(tmp)",
            "cmux-tui/bindings/java/src/main/java/Cmux.java": "+    deleteAllSurfaces();",
            NEXT + "CmuxNextHistory/HistoryStore.swift": "+    /* removeItem(at:) is never called here */",
        }
        for path, line in cases.items():
            with self.subTest(path=path):
                self.assertEqual(self.tier(path, patches={path: line}), "normal")

    def test_scripts_that_only_mention_release_are_not_high(self):
        self.assertEqual(self.tier("scripts/cmux-next/sidebar-rows-perf-release.py"), "low")
        self.assertEqual(self.tier("scripts/ci/nightly_release_notes.py"), "low")
        self.assertEqual(self.tier("scripts/ci/check-design-tokens.sh"), "normal")

    def test_a_new_delete_of_user_data_in_product_code_is_high(self):
        path = NEXT + "CmuxNextHistory/HistoryStore.swift"
        self.assertEqual(self.tier(path, patches={path: "+ try FileManager.default.removeItem(at: url)"}), "high")
        sql = "backend/apps/api/src/cleanup.ts"
        self.assertEqual(self.tier(sql, patches={sql: "+ await db.execute(`DELETE FROM sessions WHERE x`)"}), "high")
        # Removing a delete, mentioning one in a comment, or deleting in a test or a CI script is not.
        self.assertEqual(self.tier(path, patches={path: "- try FileManager.default.removeItem(at: url)"}), "normal")
        self.assertEqual(self.tier(path, patches={path: "+ // removeItem(at:) is never called here"}), "normal")
        test = "Packages/macOS/CmuxNext/Tests/X/HistoryTests.swift"
        self.assertEqual(self.tier(test, patches={test: "+ try FileManager.default.removeItem(at: tmp)"}), "low")
        ci = "scripts/ci/clean.sh"
        self.assertEqual(self.tier(ci, patches={ci: "+ rm -rf build; python -c 'shutil.rmtree(x)'"}), "normal")

    def test_a_new_privileged_workflow_trigger_is_high(self):
        # 16c570b576 put a cargo cache on pull_request_target: a fork could poison it.
        wf = ".github/workflows/cmux-tui-windows.yml"
        self.assertEqual(self.tier(wf, patches={wf: "+on:\n+  pull_request_target:\n+    branches: [main]"}), "high")
        self.assertEqual(self.tier(wf, patches={wf: "+  workflow_run:"}), "high")
        # Editing a workflow that already has one, or mentioning it, is normal.
        self.assertEqual(self.tier(wf, patches={wf: "+      run: echo pull_request_target is not used"}), "normal")
        self.assertEqual(self.tier(wf, patches={wf: "-  pull_request_target:"}), "normal")
        for inline in ("+on: pull_request_target", "+on: [push, pull_request_target]",
                       "+on: { workflow_run: { workflows: [ci] } }", '+  "pull_request_target":'):
            with self.subTest(line=inline):
                self.assertEqual(self.tier(wf, patches={wf: inline}), "high")
        self.assertEqual(self.tier(wf, patches={wf: "+    if: github.event_name == 'pull_request_target'"}), "normal")
        self.assertEqual(self.tier(wf, patches={wf: "+  push:  # not pull_request_target"}), "normal")

    def test_agent_pane_host_ops_and_allowlists_are_high(self):
        # #22646 added the page op chat.asks.pending, whose handler read another chat's permission
        # asks over the host's own acpmux connection and reached a peer daemon until review caught it.
        # It graded normal by path. What a pane page may make the host do or read is access policy.
        pane = NEXT + "CmuxNextAgentPane/"
        for path in (
            pane + "AgentPageProvider.swift",
            pane + "AcpmuxPaneMethods.swift",
            pane + "AcpmuxPaneMethods+Params.swift",
            pane + "AcpmuxPaneMethods+Answers.swift",
            pane + "AgentPaneEnvironmentRequest.swift",
            pane + "AgentPaneReplyRequest.swift",
            pane + "AgentPaneTransport+Check.swift",
            pane + "AcpmuxPathPolicy.swift",
            pane + "AgentPanePendingAsks.swift",
            pane + "AgentPaneTransport+Frames.swift",
            pane + "AgentPaneGestureIntent.swift",
            pane + "AgentPaneUserGestures.swift",
            pane + "AgentPaneModel+Actions.swift",
            pane + "AgentPaneTransport+RelayedAllow.swift",
            pane + "AgentPaneTransport+PickedFolder.swift",
            pane + "AgentPaneTransport+FullAccess.swift",
            "cmux-tui/crates/cmux-agent-pane-policy/policy.json",
            "cmux-tui/crates/cmux-agent-pane-policy/src/params.rs",
            "cmux-tui/crates/acpmux/src/server/remote_guard.rs",
        ):
            with self.subTest(path=path):
                self.assertEqual(self.tier(path), "high")

    def test_ordinary_agent_pane_ui_and_policy_tests_stay_below_high(self):
        pane = NEXT + "CmuxNextAgentPane/"
        for path in (pane + "AgentPaneView.swift", pane + "AgentPageProvider+Scroll.swift",
                     pane + "AgentPaneModel+Composer.swift", pane + "AgentPaneTransportPacer.swift"):
            with self.subTest(path=path):
                self.assertEqual(self.tier(path), "normal")
        for path in ("cmux-tui/crates/cmux-agent-pane-policy/tests/cases/params.json",
                     "cmux-tui/crates/cmux-agent-pane-policy/tests/swift.rs",
                     "cmux-tui/crates/acpmux/tests/remote_guard.rs"):
            with self.subTest(path=path):
                self.assertEqual(self.tier(path), "low")

    def test_audit_sample_of_real_pull_requests(self):
        # Each case is a merged pull request from the audit (docs/ci/risk-tiers.md), with its files.
        cases = {
            # Migration deployed before it was applied: every Cloud VM create failed for ~7h.
            16397: ("high", ["web/db/migrations/20261001000000_coderouter_vm_pool_initialization/migration.sql",
                             "web/db/schema.ts", "web/services/coderouter/repository.ts",
                             "web/tests/coderouter-vm-scope-db-behavior.test.ts"]),
            # Cookie gate change: signed-in users looped between sign-in and the dashboard in prod.
            12121: ("high", ["web/app/[locale]/dashboard/layout.tsx", "web/app/lib/dashboard-auth.ts",
                             "web/app/lib/dashboard-session.ts", "web/proxy.ts",
                             "web/tests/dashboard-layout.test.tsx"]),
            # Signed dev channel: every DEV Release compile step failed after it.
            18817: ("high", [".github/workflows/cmux-next-dev-daily.yml", ".github/workflows/cmux-next.yml",
                             "cmux.next-dev.entitlements", "docs/cmux-next/dev-daily.md",
                             "scripts/cmux-next/check-cmux-scheme-compile.sh",
                             "scripts/cmux-next/update-dev-daily.sh"]),
            # A caller sent params the existing host policy refused (P1, local chats broke). The
            # policy itself didn't change, so no path rule sees it: normal, caught by its fix.
            20644: ("normal", ["webviews/src/agent-session/acpmux/direct.ts",
                               "webviews/src/agent-session/acpmux/sessionPages.ts",
                               "webviews/test/agent-pane-session-pages.test.ts"]),
            # Unclosed CSS rule: chat pages rendered unstyled. Cosmetic, reverted in minutes.
            19473: ("normal", ["webviews/src/agent-session/acpmux/App.tsx",
                               "webviews/src/agent-session/acpmux/Localizable.xcstrings",
                               "webviews/src/agent-session/acpmux/conversation/conversation.css",
                               "webviews/src/agent-session/acpmux/generated/strings.json",
                               "webviews/test/artifact-panel.test.tsx"]),
            # A stale vendor/bonsplit pin: main stopped compiling, fixed forward the same day.
            16319: ("normal", ["cmux-tui/crates/cmux-tui-core/src/journal_ingress.rs",
                               "cmux-tui/crates/cmux-tui-core/src/resource_router/content.rs", "vendor/bonsplit"]),
            # A default flip behind a setting: undo is the setting.
            21686: ("normal", [NEXT + "CmuxNextSettings/NowPlayingSettings.swift", "schemas/defaults/cmux-next.json",
                               NEXT + "CmuxNextSettings/Localizable.xcstrings",
                               "Packages/macOS/CmuxNext/Tests/CmuxNextSettingsTests/NowPlayingSettingTests.swift"]),
            # CI wiring: the old rules made this high; a bad line here is one revert away.
            21971: ("normal", [".github/workflows/ci-guards.yml", ".github/workflows/cmux-next-media.yml",
                               "scripts/ci/media_module_cache_stamp.py", "tests/test-execution.toml",
                               "tests/test_ci_media_module_cache_stamp.py"]),
            # Docs only.
            21950: ("low", ["cmux-tui/spec/commands.md"]),
        }
        for number, (expected, files) in cases.items():
            with self.subTest(pr=number):
                self.assertEqual(self.tier(*files), expected)

    def test_replay_misgrades_stay_out_of_high(self):
        # From the replay over feat-cmux-next: names that look like release or relay work but aren't.
        for path, expected in (
            ("scripts/cmux-next/media/publish.py", "normal"),
            (NEXT + "CmuxNextUpdater/Share/ShareCmuxView.swift", "normal"),
            (NEXT + "CmuxNextUpdater/UpdateIndicatorView.swift", "normal"),
            (NEXT + "CmuxNextUpdater/Resources/Localizable.xcstrings", "low"),
            ("services/iroh-relay-minter/LICENSE", "low"),
            (NEXT + "CmuxNextUpdater/UpdateDriver.swift", "high"),
        ):
            with self.subTest(path=path):
                self.assertEqual(self.tier(path), expected)

    def test_an_update_channel_setting_is_normal_and_the_update_path_stays_high(self):
        # Leo, 2026-10-21: a settings-only channel toggle that reuses the signed feeds is normal;
        # updater install, signing and feed-verification code stays high.
        setting = ("Packages/macOS/CmuxUpdater/Sources/CmuxUpdater/UpdateRing.swift",
                   NEXT + "CmuxNextUpdater/UpdatePreferences.swift",
                   NEXT + "CmuxNextSettings/UpdatesSettings.swift",
                   NEXT + "CmuxNextSettings/Schema/SettingsSchema+Updates.generated.swift",
                   "schemas/settings/source/updates.json", "schemas/settings/settings-schema.json",
                   NEXT + "CmuxNextSettings/Localizable.xcstrings")
        self.assertEqual(self.tier(*setting), "normal")
        # UpdateTrack decides whether Sparkle runs at all, so it is the update path, not a setting.
        for path in ("UpdateTrack.swift", "AppcastParser.swift", "AppcastSelector.swift", "UpdateProber.swift",
                     "UpdaterService+Flow.swift",
                     "UpdateInstallPreflight.swift", "RollbackSwap.swift", "UpdateTransfer.swift"):
            with self.subTest(path=path):
                self.assertEqual(self.tier(*setting, NEXT + "CmuxNextUpdater/" + path), "high")

    def test_the_cmux_updater_package_is_the_update_path(self):
        # Signature verification, the feed resolver, the Sparkle driver and the install code must never
        # grade normal; only the ring above is a setting. Its tests stay low.
        updater = "Packages/macOS/CmuxUpdater/"
        for path in ("Sources/CmuxUpdater/ChannelSwitch/AppSignatureVerification.swift",
                     "Sources/CmuxUpdater/ChannelSwitch/SecurityAppSignatureInspector.swift",
                     "Sources/CmuxUpdater/ChannelSwitch/AppChannelSwitcher.swift",
                     "Sources/CmuxUpdater/UpdateFeedResolver.swift",
                     "Sources/CmuxUpdater/UpdateDriver.swift",
                     "Sources/CmuxUpdater/UpdateDriver+SPUUpdaterDelegate.swift",
                     "Sources/CmuxUpdater/UpdateDriver+BackgroundInstall.swift",
                     "Sources/CmuxUpdater/UpdateController+InstallAttempt.swift",
                     "Sources/CmuxUpdater/UpdateController+BackgroundInstall.swift",
                     "Sources/CmuxUpdater/InstallWatchdog.swift",
                     "Package.swift"):
            with self.subTest(path=path):
                self.assertEqual(self.tier(updater + path), "high")
        self.assertEqual(self.tier(updater + "Sources/CmuxUpdater/UpdateRing.swift"), "normal")
        self.assertEqual(self.tier(updater + "Tests/CmuxUpdaterTests/UpdateFeedResolverTests.swift"), "low")

    def test_highest_path_wins(self):
        self.assertEqual(self.tier("docs/x.md", NEXT + "CmuxNextSidebar/A.swift",
                                   NEXT + "CmuxNextUpdater/Feed.swift"), "high")
        self.assertEqual(self.tier("docs/x.md", NEXT + "CmuxNextSidebar/A.swift"), "normal")

    def test_split_diff_keys_hunks_by_new_path(self):
        diff = ("diff --git a/a.swift b/a.swift\n--- a/a.swift\n+++ b/a.swift\n@@ -1 +1 @@\n-x\n+y\n"
                "diff --git a/b.md b/b.md\nnew file\n--- /dev/null\n+++ b/b.md\n@@ -0,0 +1 @@\n+z\n")
        self.assertEqual(risk.split_diff(diff), {"a.swift": "@@ -1 +1 @@\n-x\n+y", "b.md": "@@ -0,0 +1 @@\n+z"})


class RecentRevertTests(unittest.TestCase):
    """A pull request that takes back another pull request's change from the last week is high."""

    def git(self, repo, *args, when=None):
        env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t",
                   GIT_COMMITTER_EMAIL="t@t")
        if when is not None:
            env["GIT_COMMITTER_DATE"] = env["GIT_AUTHOR_DATE"] = f"{int(when)} +0000"
        return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True, text=True, env=env).stdout

    def test_deleted_ranges_follow_the_base_side_line_numbers(self):
        patch = "@@ -3,4 +3,3 @@\n ctx\n-gone a\n-gone b\n ctx\n@@ -20,2 +19,2 @@\n-old\n+new\n ctx"
        self.assertEqual(risk.deleted_ranges(patch), [(4, 5), (20, 20)])

    def test_undoes_needs_the_added_lines_gone_and_the_replaced_lines_back(self):
        commit = "@@ -1,2 +1,2 @@\n-old effect\n+keyed effect\n ctx"
        self.assertTrue(risk.undoes("@@ -1,2 +1,2 @@\n-keyed effect\n+old effect\n ctx", commit))
        # Rewriting the new line into something else is ordinary editing.
        self.assertFalse(risk.undoes("@@ -1,2 +1,2 @@\n-keyed effect\n+keyed effect v2\n ctx", commit))
        # Moving the new lines elsewhere in the file is not taking them back.
        self.assertFalse(risk.undoes("@@ -1,3 +1,1 @@\n-.a{}\n-.b{}\n ctx\n@@ -40 +38,3 @@\n+.a{}\n+.b{}\n ctx",
                                     "@@ -1 +1,3 @@\n+.a{}\n+.b{}\n ctx"))
        # Moving them to another file is not taking them back either.
        self.assertFalse(risk.undoes("@@ -1,3 +1,1 @@\n-.a{}\n-.b{}\n ctx", "@@ -1 +1,3 @@\n+.a{}\n+.b{}\n ctx",
                                     frozenset({".a{}", ".b{}"})))
        # A pure addition taken out again is a revert.
        self.assertTrue(risk.undoes("@@ -1,3 +1,1 @@\n-.a{}\n-.b{}\n ctx", "@@ -1 +1,3 @@\n+.a{}\n+.b{}\n ctx"))

    def test_a_revert_of_last_weeks_change_names_its_pull_request(self):
        now = time.time()
        with tempfile.TemporaryDirectory() as repo:
            self.git(repo, "init", "-q")
            path = os.path.join(repo, "App.tsx")
            open(path, "w").write("one\ntwo\nthree\n")
            self.git(repo, "add", ".")
            self.git(repo, "commit", "-qm", "feat: old work (#100)", when=now - 30 * 86400)
            open(path, "w").write("one\ntwo\nfix from yesterday\nthree\n")
            self.git(repo, "commit", "-qam", "perf: avoid duplicate loads (#21369)", when=now - 86400)
            base = self.git(repo, "rev-parse", "HEAD").strip()
            stale = {"filename": "App.tsx", "status": "modified",
                     "patch": "@@ -1,4 +1,3 @@\n one\n two\n-fix from yesterday\n three"}
            self.assertEqual(risk.recent_reverts([stale], repo, base, own=21194, now=now), {21369: ["App.tsx"]})
            # Deleting only month-old lines, or the pull request's own lines, is not flagged.
            old = {"filename": "App.tsx", "status": "modified", "patch": "@@ -1,4 +1,3 @@\n-one\n two"}
            self.assertEqual(risk.recent_reverts([old], repo, base, own=21194, now=now), {})
            self.assertEqual(risk.recent_reverts([stale], repo, base, own=21369, now=now), {})
            # Out of time: nothing is checked, and the file is reported as unread rather than clear.
            unread = []
            self.assertEqual(risk.recent_reverts([stale], repo, base, own=21194, now=now, unread=unread, budget=0), {})
            self.assertEqual(unread, ["App.tsx"])


class RenderTests(unittest.TestCase):
    def test_a_file_name_cannot_start_a_workflow_command(self):
        name = "docs/a\n::add-mask::x`b.md"
        report = risk.render(risk.classify([name]), [])
        self.assertFalse(any(line.startswith("::") for line in report.splitlines()))
        self.assertIn("docs/a?::add-mask::x?b.md", report)
        self.assertEqual(risk.printable("a\u0085b\u2028c\u2029d"), "a?b?c?d")


class EvidenceTests(unittest.TestCase):
    def test_low_and_normal_never_wait_for_a_person(self):
        self.assertEqual(risk.missing_evidence("low"), [])
        self.assertEqual(risk.missing_evidence("normal", body=""), [])

    def test_high_is_held_only_by_a_block_on_the_head_and_warns_without_a_verdict(self):
        # No verdict yet: a warning, not a hold (the check passes and says so).
        self.assertEqual(risk.missing_evidence("high"), [])
        self.assertIn("no review verdict", risk.pending_review("high"))
        # A BLOCK or FIX that is the newest verdict on the head holds it.
        self.assertEqual(len(risk.missing_evidence("high", blocked=True)), 1)
        self.assertEqual(risk.pending_review("high", blocked=True), "")
        # A sign-off clears both; low and normal never warn.
        self.assertEqual(risk.missing_evidence("high", human_ok=True), [])
        self.assertEqual(risk.pending_review("high", human_ok=True), "")
        self.assertEqual(risk.pending_review("normal"), "")

    def test_the_evidence_command_fails_only_on_a_block(self):
        self.assertEqual(risk.main(["evidence", "--tier", "high"]), 0)
        self.assertEqual(risk.main(["evidence", "--tier", "high", "--blocked"]), 1)
        self.assertEqual(risk.main(["evidence", "--tier", "high", "--blocked", "--human-ok"]), 0)

    def test_a_takeback_holds_any_tier_until_the_description_owns_it(self):
        self.assertEqual(len(risk.missing_evidence("low", taken_back=[21369])), 1)
        body = "## Summary\nTakes back #21369: the olderLoadKey guard moved into the store\n"
        self.assertEqual(risk.missing_evidence("normal", body=body, taken_back=[21369]), [])
        # Owning one takeback doesn't clear another; a template comment doesn't count.
        self.assertEqual(len(risk.missing_evidence("normal", body=body, taken_back=[21369, 21384])), 1)
        self.assertEqual(len(risk.missing_evidence("normal", body="<!-- Takes back #21369: x -->",
                                                   taken_back=[21369])), 1)
        self.assertEqual(len(risk.missing_evidence("normal", body="Takes back #21369:", taken_back=[21369])), 1)

    def test_the_last_labeler_counts_and_a_removal_clears_it(self):
        added = {"event": "labeled", "label": {"name": "risk:human-ok"}, "actor": {"login": "leo"}}
        removed = {"event": "unlabeled", "label": {"name": "risk:human-ok"}, "actor": {"login": "leo"}}
        self.assertEqual(risk.last_labeler([added], "risk:human-ok"), "leo")
        self.assertIsNone(risk.last_labeler([added, removed], "risk:human-ok"))

    def test_only_a_person_other_than_the_author_approving_the_head_counts(self):
        def review(login, state="APPROVED", sha=HEAD, kind="User", assoc="MEMBER", at="2026-10-21T20:00:00Z"):
            return {"user": {"login": login, "type": kind}, "state": state, "commit_id": sha,
                    "author_association": assoc, "submitted_at": at, "body": ""}

        def signed(*reviews):
            return risk.signed_off([], list(reviews), HEAD, "teamleaderleo")
        self.assertEqual(signed(review("lawrencecchen")), "@lawrencecchen")
        self.assertIsNone(signed(review("teamleaderleo")))
        self.assertIsNone(signed(review("lawrencecchen", sha="f" * 40)))
        self.assertIsNone(signed(review("coderabbitai[bot]", kind="Bot")))
        self.assertIsNone(signed(review("drive-by", assoc="NONE")))
        # A later request for changes withdraws the approval; a comment doesn't.
        self.assertIsNone(signed(review("lawrencecchen"),
                                 review("lawrencecchen", "CHANGES_REQUESTED", at="2026-10-21T20:05:00Z")))
        self.assertEqual(signed(review("lawrencecchen"),
                                review("lawrencecchen", "COMMENTED", at="2026-10-21T20:05:00Z")), "@lawrencecchen")


class ShipReceiptTests(unittest.TestCase):
    def comment(self, body, at="2026-10-21T20:00:00Z", association="MEMBER", kind="User"):
        return {"body": body, "created_at": at, "author_association": association,
                "user": {"login": "teamleaderleo", "type": kind}}

    def review(self, body="", state="COMMENTED", at="2026-10-21T20:00:00Z", login="lawrencecchen"):
        return {"body": body, "state": state, "commit_id": HEAD, "submitted_at": at,
                "author_association": "MEMBER", "user": {"login": login, "type": "User"}}

    def test_an_independent_ship_at_the_full_head_signs_off(self):
        comments = [self.comment(f"Review (subagent, correctness first): SHIP at {HEAD}\n\ndetails")]
        self.assertEqual(risk.signed_off(comments, [], HEAD), "review (subagent, correctness first)")

    def test_a_short_sha_another_head_or_a_self_review_does_not(self):
        for line in (f"Review (subagent): SHIP at {HEAD[:12]}", "Review (subagent): SHIP at " + "f" * 40,
                     f"Review (self): SHIP at {HEAD}", f"Addressed review: nothing blocking at {HEAD}"):
            self.assertIsNone(risk.signed_off([self.comment(line)], [], HEAD), line)

    def test_the_receipt_must_lead_the_comment(self):
        self.assertIsNone(risk.signed_off([self.comment(f"Notes\nReview (subagent): SHIP at {HEAD}")], [], HEAD))

    def test_a_newer_block_beats_an_earlier_ship(self):
        comments = [self.comment(f"Review (subagent): SHIP at {HEAD}", at="2026-10-21T20:00:00Z"),
                    self.comment(f"Review (codex): BLOCK at {HEAD}: races", at="2026-10-21T20:05:00Z")]
        self.assertIsNone(risk.signed_off(comments, [], HEAD))
        comments.append(self.comment(f"Review (codex): SHIP at {HEAD}", at="2026-10-21T20:10:00Z"))
        self.assertEqual(risk.signed_off(comments, [], HEAD), "review (codex)")

    def test_a_block_in_a_review_body_or_a_change_request_beats_an_earlier_ship(self):
        ship = [self.comment(f"Review (subagent): SHIP at {HEAD}", at="2026-10-21T20:00:00Z")]
        later = "2026-10-21T20:05:00Z"
        self.assertIsNone(risk.signed_off(ship, [self.review(f"Review (codex): BLOCK at {HEAD}", at=later)], HEAD))
        self.assertIsNone(risk.signed_off(ship, [self.review(state="CHANGES_REQUESTED", at=later)], HEAD))
        self.assertEqual(risk.signed_off(ship, [self.review(f"Review (codex): SHIP at {HEAD}", at=later)], HEAD),
                         "review (codex)")

    def test_a_newer_block_comment_beats_an_approval(self):
        approval = [self.review(state="APPROVED", at="2026-10-21T20:00:00Z")]
        block = [self.comment(f"Review (subagent): BLOCK at {HEAD}", at="2026-10-21T20:05:00Z")]
        self.assertIsNone(risk.signed_off(block, approval, HEAD, "teamleaderleo"))

    def test_a_block_wins_a_tie(self):
        comments = [self.comment(f"Review (codex): BLOCK at {HEAD}"), self.comment(f"Review (subagent): SHIP at {HEAD}")]
        self.assertIsNone(risk.signed_off(comments, [], HEAD))

    def test_bots_and_outside_accounts_do_not_count(self):
        line = f"Review (subagent): SHIP at {HEAD}"
        self.assertIsNone(risk.signed_off([self.comment(line, kind="Bot")], [], HEAD))
        self.assertIsNone(risk.signed_off([self.comment(line, association="CONTRIBUTOR")], [], HEAD))


class DescriptionVerdictTests(unittest.TestCase):
    """A review verdict in the PR description, so a review needs no receipt comment."""

    def pr(self, body, association="MEMBER", kind="User"):
        return {"body": body, "author_association": association, "head": {"sha": HEAD},
                "user": {"login": "teamleaderleo", "type": kind}, "labels": []}

    def comment(self, body, at="2026-10-21T20:00:00Z"):
        return {"body": body, "created_at": at, "author_association": "MEMBER",
                "user": {"login": "teamleaderleo", "type": "User"}}

    def state(self, body, comments=(), **pr):
        """(signed off, blocked, warning) as pr_mode grades a high pull request, without the API."""
        pull = self.pr(body, **pr)
        found = risk.head_verdicts(list(comments), [], HEAD, "teamleaderleo", pull)
        who = risk.signed_off(list(comments), [], HEAD, "teamleaderleo", pull) if found else None
        blocked = bool(found) and who is None
        return who, blocked, risk.missing_evidence("high", who is not None, body, blocked=blocked), \
            risk.pending_review("high", who is not None, blocked)

    def test_a_ship_line_at_the_head_in_the_description_signs_off(self):
        body = f"## Summary\nFixes the gate.\n\nReview (codex gpt-6-astra xhigh): SHIP at {HEAD}\n"
        who, blocked, missing, pending = self.state(body)
        self.assertEqual(who, "review (codex gpt-6-astra xhigh) in the description")
        self.assertEqual((blocked, missing, pending), (False, [], ""))
        # A list item or quote around it still counts.
        self.assertIsNotNone(self.state(f"- Review (codex): SHIP at {HEAD}")[0])

    def test_a_ship_at_an_older_head_is_no_verdict_and_only_warns(self):
        who, blocked, missing, pending = self.state("Review (codex): SHIP at " + "f" * 40)
        self.assertEqual((who, blocked, missing), (None, False, []))
        self.assertIn("no review verdict", pending)
        # Nor does a short sha, a self-review, or a line inside an HTML comment.
        for body in (f"Review (codex): SHIP at {HEAD[:12]}", f"Review (self): SHIP at {HEAD}",
                     f"<!--\nReview (codex): SHIP at {HEAD}\n-->"):
            self.assertEqual(self.state(body)[:3], (None, False, []), body)

    def test_a_fix_or_block_at_the_head_holds(self):
        for word in ("FIX", "BLOCK"):
            who, blocked, missing, pending = self.state(f"Review (codex): {word} at {HEAD}: races")
            self.assertEqual((who, blocked, pending), (None, True, ""), word)
            self.assertEqual(len(missing), 1, word)
        # A FIX and a SHIP in the same description: the block wins the tie.
        self.assertTrue(self.state(f"Review (a): SHIP at {HEAD}\nReview (b): FIX at {HEAD}")[1])

    def test_no_verdict_only_warns(self):
        self.assertEqual(self.state("## Summary\nNothing about a review here.")[:3], (None, False, []))

    def test_a_comment_ship_still_signs_off_and_a_later_comment_block_beats_the_description(self):
        ship = self.comment(f"Review (subagent): SHIP at {HEAD}")
        self.assertEqual(self.state("no verdict here", [ship])[0], "review (subagent)")
        block = self.comment(f"Review (codex): BLOCK at {HEAD}: races")
        self.assertTrue(self.state(f"Review (codex): SHIP at {HEAD}", [block])[1])
        # And a comment SHIP clears a FIX line left in the description.
        self.assertEqual(self.state(f"Review (codex): FIX at {HEAD}", [ship])[0], "review (subagent)")

    def test_the_description_author_is_trusted_like_a_commenter(self):
        line = f"Review (codex): SHIP at {HEAD}"
        self.assertIsNone(self.state(line, association="CONTRIBUTOR")[0])
        self.assertIsNone(self.state(line, association="NONE")[0])
        self.assertIsNone(self.state(line, kind="Bot")[0])

    def test_the_grade_passes_with_a_warning_and_holds_on_a_block(self):
        """pr_mode end to end with the API stubbed: ready is false only for a BLOCK or FIX on the head."""
        def grade(body, comments=()):
            pull = dict(self.pr(body), base={"sha": "b" * 40})
            answers = {
                "repos/o/r/pulls/7/files?per_page=100": [{"filename": "scripts/ci/risk_tier.py", "patch": ""}],
                "repos/o/r/issues/7/comments?per_page=100": None if comments is None else list(comments),
                "repos/o/r/pulls/7/reviews?per_page=100": [],
                "repos/o/r/issues/7/events?per_page=100": [],
            }
            saved = risk.gh_items, risk.gh_json

            def items(endpoint):
                if answers[endpoint] is None:
                    raise subprocess.CalledProcessError(1, ["gh", "api", endpoint])
                return answers[endpoint]
            risk.gh_items = items
            risk.gh_json = lambda *args: pull
            try:
                with tempfile.TemporaryDirectory() as tmp:
                    out, summary = Path(tmp) / "out", Path(tmp) / "summary"
                    risk.main(["pr", "--repo", "o/r", "--number", "7", "--github-output", str(out),
                               "--summary", str(summary)])
                    return out.read_text(), summary.read_text()
            finally:
                risk.gh_items, risk.gh_json = saved

        out, summary = grade(f"Review (codex): SHIP at {HEAD}")
        self.assertIn("tier=high", out)
        self.assertIn("ready=true", out)
        self.assertIn("Signed off: review (codex) in the description shipped", summary)
        out, summary = grade("no verdict")
        self.assertIn("ready=true", out)
        self.assertIn("Warning: no review verdict", summary)
        out, summary = grade(f"Review (codex): FIX at {HEAD}")
        self.assertIn("ready=false", out)
        out, _ = grade("no verdict", [self.comment(f"Review (subagent): SHIP at {HEAD}")])
        self.assertIn("ready=true", out)
        # An unreadable comment read could hide a BLOCK: it holds, and never only warns.
        out, summary = grade("no verdict", None)
        self.assertIn("ready=false", out)
        self.assertIn("could not be read", summary)
        self.assertNotIn("Warning:", summary)


if __name__ == "__main__":
    unittest.main()
