// The workspaces, panes and tabs a cmux link can name, by their resource ids, as the host pushes
// them (`linkPlaces`: each window's workspaces with their titles and the machine they are on). A
// module store like needsYou/attentionTabs.ts, so a push that arrives before the transcript mounts
// is kept, and one map built per push: a chip reads its place in O(1) however many workspaces
// there are (rulebook: interaction cost stays constant as workspaces grow). A rename is a new push,
// so a chip's title follows it; an id no push names (closed, deleted, another person's) has no place,
// and its link stays the plain link.
import { useSyncExternalStore } from "react";

export type CmuxLinkPlace = {
  /// `ws_…`, `pane_…` or `tab_…`.
  id: string;
  kind: "workspace" | "pane" | "tab";
  title: string;
  /// The machine it runs on, when not this Mac.
  host?: string;
  /// A tab's or pane's workspace, by its title.
  workspace?: string;
};

/// The host event that replaces the list (pageHost.ts).
export const LINK_PLACES_EVENT = "linkPlaces";
/// Longest title a pushed field keeps.
const MAX_TEXT = 256;
/// The most places one push keeps: past it the rest stay plain links.
export const MAX_PLACES = 4096;
const ID = /^(?:ws|pane|tab)_[0-9a-f]{32}$/;

let places = new Map<string, CmuxLinkPlace>();
let version = 0;
const listeners = new Set<() => void>();

const text = (value: unknown) => (typeof value === "string" ? value.trim().slice(0, MAX_TEXT) : "");

/// The pushed list's well-formed entries, by id; anything malformed is dropped.
export function parseLinkPlaces(value: unknown): Map<string, CmuxLinkPlace> {
  const out = new Map<string, CmuxLinkPlace>();
  if (!Array.isArray(value)) return out;
  for (const raw of value as unknown[]) {
    if (out.size >= MAX_PLACES) break;
    if (!raw || typeof raw !== "object") continue;
    const entry = raw as Record<string, unknown>;
    const id = typeof entry.id === "string" ? entry.id : "";
    const kind = entry.kind;
    const title = text(entry.title);
    if (!ID.test(id) || !title) continue;
    if (kind !== "workspace" && kind !== "pane" && kind !== "tab") continue;
    if (!id.startsWith(kind === "workspace" ? "ws_" : `${kind}_`)) continue;
    const host = text(entry.host);
    const workspace = text(entry.workspace);
    out.set(id, { id, kind, title, ...(host && { host }), ...(workspace && { workspace }) });
  }
  return out;
}

/// Replaces the places from a host push.
export function setLinkPlaces(value: unknown): void {
  places = parseLinkPlaces(value);
  version += 1;
  for (const listener of listeners) listener();
}

/// The place `id` names, or undefined.
export function linkPlace(id: string): CmuxLinkPlace | undefined {
  return places.get(id);
}

/// Rises with every push (the composer redraws its chips on it).
export function linkPlacesVersion(): number {
  return version;
}

export function subscribeLinkPlaces(listener: () => void): () => void {
  listeners.add(listener);
  return () => void listeners.delete(listener);
}

/// The place `id` names, live: a rename or a close redraws only the chips that name it.
export function useLinkPlace(id: string | undefined): CmuxLinkPlace | undefined {
  const read = () => (id ? places.get(id) : undefined);
  return useSyncExternalStore(subscribeLinkPlaces, read, read);
}
