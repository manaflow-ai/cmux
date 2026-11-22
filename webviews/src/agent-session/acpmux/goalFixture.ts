// l10n-allow-file: a debug fixture's goal, not shipped UI.
// A running goal over the composer, for `debug.agent_pane seed_rows` with `fixture: "goal"`, so a
// capture shows the Goal banner heading the composer in the real app (user 2026-11-20, "ensure all
// border colors are the same", on that banner): the worked turn's rows under a running Codex goal.
import type { SeedSnapshotFields } from "./waitingSteersFixture";

/// The snapshot fields a running goal brings beside the worked turn's rows, started `at`.
export function goalSnapshot(at: number): SeedSnapshotFields {
  return {
    isWorking: true,
    waitingSteers: undefined,
    newestOwnSteer: undefined,
    summary: {
      goal: {
        objective:
          "Fix Cloudflare security-key (WebAuthn get, allowCredentials) failure in cmux browser, red-test-first, landed on feat-cmux-next",
        status: "running",
        provider: "codex",
        startedAt: at - 84_000,
        updatedAt: at,
        elapsedMs: 84_000,
      },
    },
  };
}
