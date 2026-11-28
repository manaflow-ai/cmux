// The agent, model and effort picked for chats that start on a Cloud machine (cmux#51731). Cloud
// (Cloud and Auto Cloud) has its own bucket of picks, kept apart from This Mac's (lastPick.ts): a
// pick here starts no chat on this Mac (a `chat.new` on this Mac would fail for an agent only the
// machine carries, and an effort pick that started one swapped the chips to this Mac's chat and its
// provider), and it never becomes this Mac's remembered pick. The composer shows it and the Cloud send
// names it (PaneComposer.tsx). The person's pick is the only thing that changes it: it is kept in this
// viewer's storage, so the next Cloud chat starts on what the person picked last for Cloud, never on
// This Mac's pick or a default. A started Cloud chat's pick of another agent hands it to the new Cloud
// chat it opens (commandPlace.ts), which holds it here.
import { useSyncExternalStore } from "react";

export type CloudAgentPick = { harness: string; model?: string; effort?: string };

const STORAGE_KEY = "cmux.acpmux.cloudPick";

let held: CloudAgentPick | undefined;
let loaded = false;
const listeners = new Set<() => void>();

function emit() {
  for (const listener of listeners) listener();
}

function clean(pick: Partial<CloudAgentPick> | null | undefined): CloudAgentPick | undefined {
  if (!pick || typeof pick.harness !== "string" || !pick.harness || pick.harness.length > 128) return undefined;
  const model = typeof pick.model === "string" && pick.model && pick.model.length <= 256 ? pick.model : undefined;
  const effort = typeof pick.effort === "string" && pick.effort && pick.effort.length <= 128 ? pick.effort : undefined;
  return { harness: pick.harness, ...(model ? { model } : {}), ...(effort ? { effort } : {}) };
}

function load(): CloudAgentPick | undefined {
  if (!loaded) {
    loaded = true;
    try {
      held = clean(JSON.parse(globalThis.localStorage?.getItem(STORAGE_KEY) ?? "null") as Partial<CloudAgentPick>);
    } catch {
      held = undefined;
    }
  }
  return held;
}

function store(pick: CloudAgentPick | undefined): void {
  held = pick;
  loaded = true;
  try {
    if (pick) globalThis.localStorage?.setItem(STORAGE_KEY, JSON.stringify(pick));
    else globalThis.localStorage?.removeItem(STORAGE_KEY);
  } catch {
    // Storage unavailable: the pick still holds for this page.
  }
  emit();
}

/** Holds `pick` for the next Cloud start; a later pick replaces it. A pick of the same agent that
 * names no effort keeps the effort picked before (a model pick never resets the person's level). */
export function holdCloudAgentPick(pick: CloudAgentPick): void {
  const before = load();
  const next = clean({
    ...pick,
    effort: pick.effort ?? (before?.harness === pick.harness ? before.effort : undefined),
  });
  if (!next) return;
  store(next);
}

/** Holds an effort picked for the Cloud agent the chips show (`harness`), with its model. */
export function holdCloudEffortPick(harness: string | undefined, model: string | undefined, effort: string): void {
  if (!harness || !effort) return;
  const before = load();
  const keptModel = model ?? (before?.harness === harness ? before.model : undefined);
  store(clean({ harness, ...(keptModel ? { model: keptModel } : {}), effort }));
}

/** The held pick, if any. */
export function cloudAgentPick(): CloudAgentPick | undefined {
  return load();
}

/** Tests only: drops the pick. */
export function clearCloudAgentPick(): void {
  store(undefined);
}

export function useCloudAgentPick(): CloudAgentPick | undefined {
  return useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    load,
    load,
  );
}
