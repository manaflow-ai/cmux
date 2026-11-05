// l10n-allow-file: debug fixture prompts and replies, not shipped UI.
// Three steers the agent has not read yet, under a running turn, for `debug.agent_pane seed_rows` with
// `fixture: "waiting-steers"`, so a capture shows their footers in the real app: at rest only the newest
// offers Send now; hovered, Copy, Retry and the X come first and Send now last (PendingSteer.tsx). The
// same chat as the gallery's `agent-pane.queued-user-footer` `stack` variant: a Claude Code chat
// (acpmux `backgroundsWork`), so the X shows, with the newest steer as the snapshot's `newestOwnSteer`.
import type { AcpmuxRow, AcpmuxSnapshot } from "./model";

const SECOND = 1_000;

export const WAITING_STEER_IDS = ["waiting-steer-1", "waiting-steer-2", "waiting-steer-3"] as const;

/// The snapshot fields acpmux would send with these rows, which a debug seed sets beside them.
export type SeedSnapshotFields = Pick<AcpmuxSnapshot, "isWorking" | "waitingSteers" | "newestOwnSteer"> & {
  summary: { steering: boolean; backgroundsWork: boolean };
};

export const WAITING_STEERS_SNAPSHOT: SeedSnapshotFields = {
  isWorking: true,
  waitingSteers: WAITING_STEER_IDS,
  newestOwnSteer: WAITING_STEER_IDS[2],
  summary: { steering: true, backgroundsWork: true },
};

/// The turn the agent is on, from `at`, then the three steers, oldest first, 15 s apart.
export function waitingSteersRows(at: number): AcpmuxRow[] {
  const steers = [
    "Use the cache dir, not tmp",
    "And keep the old run's logs",
    "Use the cache directory for the next run",
  ];
  return [
    { id: "waiting-steer-prompt", version: 1, at, kind: "user", text: "Check the cache" },
    {
      id: "waiting-steer-reply",
      version: 1,
      at: at + 2 * SECOND,
      kind: "assistant",
      text: "Checking the cache.",
      streaming: true,
    },
    ...steers.map((text, index): AcpmuxRow => ({
      id: WAITING_STEER_IDS[index]!,
      version: 1,
      at: at + (30 + index * 15) * SECOND,
      kind: "user",
      text,
      steer: "waiting",
      steerPromptId: `waiting-steer-prompt-${index + 1}`,
    })),
  ];
}
