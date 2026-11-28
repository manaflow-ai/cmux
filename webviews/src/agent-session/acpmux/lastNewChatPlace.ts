/// Where the person last picked to start a new chat (cmux#46019): This Mac, Cloud, or another
/// machine acpmux lists. A new workspace (Cmd-N) opens a new New Tab page, whose run mode and machine
/// start empty; this is what makes the pick hold for the next one instead of going back to This Mac.
///
/// Kept in this origin's localStorage, which every agent page shares (newtab/settledCache.ts), so a
/// pick on one workspace's page reaches the next workspace's page. Only the person's own picks are
/// written (the composer's Where menu, the New Tab page's location row, New Cloud Chat); a default
/// from a folder's history or an automation's run mode never is. Sandboxed is a one-off run, never
/// a place, so it leaves what is kept as it was. Auto (autoWhereModel.ts) is kept as itself: the next
/// new chat is Auto too, and its Send asks where.
import { newChatPick, type PickStore } from "./newChatPicks";
import type { RunLocation } from "./runLocationDefault";

export type PickedPlace = { kind: "local" } | { kind: "cloud" } | { kind: "auto" } | { kind: "machine"; peer: string };

export type PlaceStore = PickStore;

/// The kept place (newChatPicks.ts: one store for every new chat's composer picks, cmux#57157).
const kept = newChatPick<PickedPlace>("cmux.agentPane.lastNewChatPlace", (value) => {
  if (!value || typeof value !== "object" || !("kind" in value)) return undefined;
  if (value.kind === "local" || value.kind === "cloud" || value.kind === "auto") return { kind: value.kind };
  if (value.kind === "machine" && "peer" in value && typeof value.peer === "string" && value.peer)
    return { kind: "machine", peer: value.peer };
  return undefined;
});

/// The place last picked, or undefined (none yet, no storage, or a value this build can't read).
export function lastNewChatPlace(store?: PlaceStore): PickedPlace | undefined {
  return kept.get(store);
}

export function rememberNewChatPlace(place: PickedPlace, store?: PlaceStore): void {
  kept.set(place, store);
}

/// `lastNewChatPlace()`, drawn again when this page or another one picks (cmux#57157). A page the
/// app keeps ready (the New Tab spare, an idle New Tab page a split or a new workspace adopts) was
/// loaded before the pick: read once per chat, it kept the place it read then.
export function useLastNewChatPlace(): PickedPlace | undefined {
  return kept.use();
}

/// The run mode a pick names (sandboxRun.ts RunMode): Cloud, or This Mac for This Mac and any other
/// machine (its chat runs persistently there). Sandboxed names no place.
export function placeOfRunMode(mode: "persistent" | "cloud" | "sandboxed"): PickedPlace | undefined {
  return mode === "cloud" ? { kind: "cloud" } : mode === "persistent" ? { kind: "local" } : undefined;
}

/// Where a new chat runs by the last pick (runLocationDefault.ts newChatRunLocation): Cloud for
/// Cloud; This Mac for This Mac and for another machine, whose chat is not a Cloud start. Auto names
/// no run location: the daemon picks on Send, and until then the folder's default holds.
export function pickedRunLocation(place: PickedPlace | undefined): RunLocation | undefined {
  if (!place || place.kind === "auto") return undefined;
  return place.kind === "cloud" ? "cloud" : "local";
}

/// The machine a new New Tab page starts on by the last pick: only while acpmux lists it and does not
/// say it is disconnected, and never when the new chat runs on Cloud anyway (Settings' Start New
/// Chats In says Cloud), so the page never names a machine a send would not go to.
export function pickedStartMachine(
  place: PickedPlace | undefined,
  runDefault: RunLocation | undefined,
  peers: readonly string[] | undefined,
  peerConnected?: Readonly<Record<string, boolean>>,
): string | undefined {
  if (place?.kind !== "machine" || runDefault === "cloud") return undefined;
  if (!peers?.includes(place.peer) || peerConnected?.[place.peer] === false) return undefined;
  return place.peer;
}
