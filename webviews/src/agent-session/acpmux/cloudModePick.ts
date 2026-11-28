// The permission mode picked for a new chat whose first send starts it on a Cloud machine (the chat
// composer with Cloud picked). The chip shows it (`AcpmuxSnapshot.cloudStartMode`) and that send
// carries it to the machine (`CloudStart.mode`), which starts the chat in it when the machine is the
// person's own (cmux-tui agent_session_start.rs). Leo, 2026-11-10: "but shouldnt the user be allowed
// to just go through with stuff?". The pick is the person's last one for every new Cloud chat
// (newChatPicks.ts, cmux#57157): a new workspace, tab or split with Cloud picked starts in it too.
import { cloudStartAgent } from "./harnessModes";
import { newChatPick } from "./newChatPicks";

type Pick = { harness: string | undefined; mode: string };

const kept = newChatPick<Pick>("cmux.agentPane.newChat.cloudMode", (value) => {
  const pick = value as Partial<Pick> | null;
  if (typeof pick?.mode !== "string" || !pick.mode) return undefined;
  if (pick.harness !== undefined && typeof pick.harness !== "string") return undefined;
  return { harness: pick.harness, mode: pick.mode };
});

/** Holds `mode` as the pick for the next Cloud start on `harness`, on this page and every new one. */
export function holdCloudModePick(harness: string | undefined, mode: string): void {
  kept.set({ harness, mode });
}

/** The held pick's mode for `harness`; none when nothing is held or it was picked on another harness. */
export function cloudModePickFor(pick: Pick | undefined, harness: string | undefined): string | undefined {
  return pick && pick.harness === harness ? pick.mode : undefined;
}

/** The Cloud send's `mode` for `harness`. The pick stays held: a send that is refused, held for a
 * check or a sign-in, or retried goes again in the same mode, and so does the next new Cloud chat.
 * A pick on another harness or a move back to this Mac never applies it. */
export function cloudStartModePick(harness: string | undefined): { mode?: string } {
  const mode = cloudModePickFor(kept.get(), harness);
  return mode ? { mode } : {};
}

/** Tests only: drops the pick. */
export function clearCloudModePick(): void {
  kept.set(undefined);
}

export function useCloudModePick(): Pick | undefined {
  return kept.use();
}

/** What a Cloud send says about its agent for a chat the composer shows on `harness`: the harness
 * and model when the machine runs that agent, else neither (the machine starts its default, Claude,
 * which the Mode chip names: cloudStartAgent), and the mode picked on the chip either way. */
export function cloudSendAgent(
  family: string | undefined,
  harness: string,
  model: string | undefined,
  cloudOnly = false,
): { harness?: string; model?: string; mode?: string; cloudOnly?: true } {
  const pick = { ...cloudStartModePick(harness), ...(cloudOnly ? { cloudOnly: true as const } : {}) };
  const agent = cloudStartAgent(family, harness);
  if (!agent.named) return pick;
  // The agent the machine runs: a Mac-only profile (claude-sr2) starts its base agent there, with its model.
  return { harness: agent.harness ?? harness, ...(model ? { model } : {}), ...pick };
}
