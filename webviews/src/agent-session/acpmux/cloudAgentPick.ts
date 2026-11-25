// The agent and model picked for a new chat whose first send starts it on a Cloud machine (cmux#51731).
// With Cloud picked the pick is the machine's, not this Mac's: it starts no chat here (a `chat.new` on
// this Mac would fail for an agent only the machine carries) and never becomes this Mac's remembered
// pick (lastPick.ts). The composer shows it and the Cloud send names it (PaneComposer.tsx). A started
// Cloud chat's pick of another agent hands it to the new Cloud chat it opens (commandPlace.ts), which
// holds it here. As cloudModePick.ts holds the mode, the pick is the person's last one for every new
// Cloud chat (newChatPicks.ts, cmux#57157): a new workspace, tab or split with Cloud picked names it too.
import { newChatPick } from "./newChatPicks";

export type CloudAgentPick = { harness: string; model?: string };

const kept = newChatPick<CloudAgentPick>("cmux.agentPane.newChat.cloudAgent", (value) => {
  const pick = value as Partial<CloudAgentPick> | null;
  if (typeof pick?.harness !== "string" || !pick.harness) return undefined;
  return typeof pick.model === "string" && pick.model
    ? { harness: pick.harness, model: pick.model }
    : { harness: pick.harness };
});

/** Holds `pick` for the next Cloud start, on this page and every new one; a later pick replaces it. */
export function holdCloudAgentPick(pick: CloudAgentPick): void {
  if (!pick.harness) return;
  kept.set(pick.model ? { harness: pick.harness, model: pick.model } : { harness: pick.harness });
}

/** The held pick, if any. */
export function cloudAgentPick(): CloudAgentPick | undefined {
  return kept.get();
}

/** Tests only: drops the pick. */
export function clearCloudAgentPick(): void {
  kept.set(undefined);
}

export function useCloudAgentPick(): CloudAgentPick | undefined {
  return kept.use();
}
