// The agent and model picked for a new chat whose first send starts it on a Cloud machine (cmux#51731).
// With Cloud picked the pick is the machine's, not this Mac's: it starts no chat here (a `chat.new` on
// this Mac would fail for an agent only the machine carries) and never becomes this Mac's remembered
// pick (lastPick.ts). The composer shows it and the Cloud send names it (PaneComposer.tsx). A started
// Cloud chat's pick of another agent hands it to the new Cloud chat it opens (commandPlace.ts), which
// holds it here. One page holds one pick, as cloudModePick.ts holds the mode; a start that opens its
// chat closes this page.
import { useSyncExternalStore } from "react";

/// `effort`: the level picked for it (cmux#59716), which the Cloud send carries; it stays with the
/// agent across a model pick, and a pick of another agent drops it.
export type CloudAgentPick = { harness: string; model?: string; effort?: string };

let held: CloudAgentPick | undefined;
const listeners = new Set<() => void>();

function emit() {
  for (const listener of listeners) listener();
}

/** Holds `pick` for the next Cloud start; a later pick replaces it. A pick of the same agent with no
 * level keeps the level already held for it. */
export function holdCloudAgentPick(pick: CloudAgentPick): void {
  if (!pick.harness) return;
  const effort = pick.effort ?? (held?.harness === pick.harness ? held.effort : undefined);
  held = {
    harness: pick.harness,
    ...(pick.model ? { model: pick.model } : {}),
    ...(effort ? { effort } : {}),
  };
  emit();
}

/** Holds `effort` for the Cloud start of `harness` (the agent the chips show), keeping its held model,
 * else `model`, the one the chips show for it, so a level picked alone never drops the shown model.
 * A level is a Cloud pick like the model: this Mac starts no chat for it (cmux#59716: a level picked
 * on a New Tab with Cloud started this Mac's own agent, and the chips showed that agent). */
export function holdCloudAgentEffort(harness: string | undefined, effort: string, model?: string): void {
  if (!harness || !effort) return;
  const base = held?.harness === harness ? held : { harness, ...(model ? { model } : {}) };
  held = { ...base, effort };
  emit();
}

/** The held pick, if any. */
export function cloudAgentPick(): CloudAgentPick | undefined {
  return held;
}

/** Drops the pick: a page another tab adopts (App.tsx adoption), a pick of an agent on This Mac. */
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
