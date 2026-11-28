// The agent, model and effort picked for a new chat whose first send starts it on a Cloud machine
// (cmux#51731). Cloud (Cloud and Auto Cloud) has its own bucket of picks, kept apart from This Mac's
// (lastPick.ts): a pick here starts no chat on this Mac (a `chat.new` on this Mac would fail for an
// agent only the machine carries, and an effort pick that started one swapped the chips to this Mac's
// chat and its provider), and it never becomes this Mac's remembered pick. The composer shows it and
// the Cloud send names it (PaneComposer.tsx). Only the person's pick changes it (Leo 2026-11-28: "Only
// explicit human clicks may update saved picks."); it is also Cloud's remembered pick
// (cloudLastPick.ts), so the next Cloud page starts on it. A started Cloud chat's pick of another
// agent hands it to the new Cloud chat it opens (commandPlace.ts), which holds it here. One page holds
// one pick, as cloudModePick.ts holds the mode; a start that opens its chat closes this page.
import { useSyncExternalStore } from "react";
import { cloudLastPick, rememberCloudPick } from "./cloudLastPick";

export type CloudAgentPick = { harness: string; model?: string; effort?: string };

let held: CloudAgentPick | undefined;
const listeners = new Set<() => void>();

function emit() {
  for (const listener of listeners) listener();
}

function hold(pick: CloudAgentPick): void {
  held = {
    harness: pick.harness,
    ...(pick.model ? { model: pick.model } : {}),
    ...(pick.effort ? { effort: pick.effort } : {}),
  };
  rememberCloudPick(held);
  emit();
}

/** What this page holds, else Cloud's remembered pick: the base a later pick of one part keeps. */
function before(): CloudAgentPick | undefined {
  return held ?? cloudLastPick();
}

/** Holds `pick` for the next Cloud start; a later pick replaces it. A pick of the same agent that
 * names no effort keeps the effort picked before (a model pick never resets the person's level). */
export function holdCloudAgentPick(pick: CloudAgentPick): void {
  if (!pick.harness) return;
  const prior = before();
  const sameAgent = prior?.harness === pick.harness;
  hold({ ...pick, effort: pick.effort ?? (sameAgent ? prior?.effort : undefined) });
}

/** Holds an effort picked for the Cloud agent the chips show (`harness`), with its model. */
export function holdCloudEffortPick(harness: string | undefined, model: string | undefined, effort: string): void {
  if (!harness || !effort) return;
  const prior = before();
  const keptModel = model ?? (prior?.harness === harness ? prior.model : undefined);
  hold({ harness, ...(keptModel ? { model: keptModel } : {}), effort });
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
