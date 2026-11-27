// The agent and model picked for a new chat whose first send starts it on a Cloud machine (cmux#51731).
// With Cloud picked the pick is the machine's, not this Mac's: it starts no chat here (a `chat.new` on
// this Mac would fail for an agent only the machine carries) and never becomes this Mac's remembered
// pick (lastPick.ts). The composer shows it and the Cloud send names it (PaneComposer.tsx). A started
// Cloud chat's pick of another agent hands it to the new Cloud chat it opens (commandPlace.ts), which
// holds it here. One page holds one pick, as cloudModePick.ts holds the mode; a start that opens its
// chat closes this page.
import { useSyncExternalStore } from "react";

export type CloudAgentPick = { harness: string; model?: string };

let held: CloudAgentPick | undefined;
const listeners = new Set<() => void>();

function emit() {
  for (const listener of listeners) listener();
}

/** Holds `pick` for the next Cloud start; a later pick replaces it. */
export function holdCloudAgentPick(pick: CloudAgentPick): void {
  if (!pick.harness) return;
  held = pick.model ? { harness: pick.harness, model: pick.model } : { harness: pick.harness };
  emit();
}

/** The held pick, if any. */
export function cloudAgentPick(): CloudAgentPick | undefined {
  return held;
}

/** Tests only: drops the pick. */
export function clearCloudAgentPick(): void {
  held = undefined;
  emit();
}

export function useCloudAgentPick(): CloudAgentPick | undefined {
  return useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    () => held,
    () => held,
  );
}
