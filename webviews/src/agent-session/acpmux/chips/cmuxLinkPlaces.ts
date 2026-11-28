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

/// Takes the renamed places of a `linkPlacesChanged` push: each place the list holds gets its new
/// name, in place, in O(renamed). One the list does not hold (past `MAX_PLACES`, or come since the last
/// whole push, which the host sends whole) is left out. Listeners hear it only when a place changed.
export function updateLinkPlaces(value: unknown): void {
  let changed = false;
  for (const place of parseLinkPlaces(value).values()) {
    const held = places.get(place.id);
    if (!held || samePlace(held, place)) continue;
    places.set(place.id, place);
    changed = true;
  }
  if (!changed) return;
  version += 1;
  for (const listener of listeners) listener();
}

const samePlace = (a: CmuxLinkPlace, b: CmuxLinkPlace) =>
  a.kind === b.kind && a.title === b.title && a.host === b.host && a.workspace === b.workspace;

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
