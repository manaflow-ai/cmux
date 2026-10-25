// The Inspector's state (ChatInspector.tsx): whether it is open, how wide it is, and which of its
// sections are folded. Each chat pane has its own (Leo, 2026-10-25: "it opens and closes on the
// other side too when you do one... they should all be individual per pane"): a toggle, a drag or a
// fold in one pane never reaches another. Every chat pane is its own page, so the page's copy is the
// pane's; it is kept in localStorage under the chat's session (``bindInspectorPane``) so the pane
// shows it again after a relaunch, and no page listens for another's writes. The last choice made in
// any pane is the default for a pane with none of its own yet (a new chat), so the Inspector still
// opens for a first chat and stays off for new chats once closed (Leo, 2026-10-20). With no storage
// (a private window, a test) the page's own copy holds them.
import { useSyncExternalStore } from "react";

export type InspectorSectionId =
  | "environment"
  | "context"
  | "connectors"
  | "changes"
  | "servers"
  | "subagents"
  | "tasks"
  | "outputs";
export type InspectorSections = Readonly<Record<InspectorSectionId, boolean>>;

/// The width a drag can give it, in px, and the width it opens at the first time.
export const INSPECTOR_WIDTH = { min: 260, max: 560, fallback: 320 } as const;

/// Context and Connectors start folded to their one-line values (as in Claude Code desktop); the
/// rest start open.
export const DEFAULT_SECTIONS: InspectorSections = {
  environment: true,
  context: false,
  connectors: false,
  changes: true,
  servers: true,
  subagents: true,
  tasks: true,
  outputs: true,
};

/// The last choice made in any pane: the defaults for a pane with no state of its own. These were
/// the one shared state before 2026-10-25, so an old install's choice is the default too.
const OPEN_KEY = "cmux.agentPane.inspector.open";
const WIDTH_KEY = "cmux.agentPane.inspector.width";
const SECTIONS_KEY = "cmux.agentPane.inspector.sections";
/// Each pane's own state, by its chat's session id: `{ [sessionId]: { open, width, sections, at } }`.
export const INSPECTOR_PANES_KEY = "cmux.agentPane.inspector.panes";
/// The panes kept: the newest ``PANES_KEPT`` chats seen in the last ``PANE_DAYS`` days.
export const PANES_KEPT = 200;
const PANE_DAYS = 30;

export type InspectorState = { readonly open: boolean; readonly width: number; readonly sections: InspectorSections };
type State = InspectorState;
type Stored = { open?: unknown; width?: unknown; sections?: unknown; at?: unknown };

const clampWidth = (width: number) => Math.round(Math.min(INSPECTOR_WIDTH.max, Math.max(INSPECTOR_WIDTH.min, width)));
const widthOf = (value: unknown) =>
  typeof value === "number" && Number.isFinite(value) && value > 0 ? clampWidth(value) : INSPECTOR_WIDTH.fallback;

function sectionsOf(value: unknown): InspectorSections {
  if (!value || typeof value !== "object") return DEFAULT_SECTIONS;
  const stored = value as Partial<Record<InspectorSectionId, unknown>>;
  const sections = { ...DEFAULT_SECTIONS };
  for (const id of Object.keys(DEFAULT_SECTIONS) as InspectorSectionId[])
    if (typeof stored[id] === "boolean") sections[id] = stored[id];
  return sections;
}

function parse(raw: string | null): unknown {
  try {
    return raw ? JSON.parse(raw) : undefined;
  } catch {
    return undefined;
  }
}

/// One pane's Inspector state: what it shows, and the pane it is saved under once its chat has a
/// session. `storage` is the page's localStorage (a test passes its own).
export function createInspectorStore(storage: () => Storage | undefined = () => globalThis.localStorage) {
  const read = (key: string): string | null => {
    try {
      return storage()?.getItem(key) ?? null;
    } catch {
      return null;
    }
  };
  const write = (key: string, value: string | null) => {
    try {
      if (value === null) storage()?.removeItem(key);
      else storage()?.setItem(key, value);
    } catch {
      // Storage off: the page's copy still holds it.
    }
  };
  const panes = (): Record<string, Stored> => {
    const value = parse(read(INSPECTOR_PANES_KEY));
    return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, Stored>) : {};
  };
  /// Open unless the viewer closed it: a first chat shows it.
  const defaults = (): State => ({
    open: read(OPEN_KEY) !== "0",
    width: widthOf(Number(read(WIDTH_KEY))),
    sections: sectionsOf(parse(read(SECTIONS_KEY))),
  });
  const own = (pane: string): State | undefined => {
    const stored = panes()[pane];
    if (!stored || typeof stored !== "object" || typeof stored.open !== "boolean") return undefined;
    return { open: stored.open, width: widthOf(stored.width), sections: sectionsOf(stored.sections) };
  };
  /// Saves `next` as `pane`'s, dropping panes past the newest ``PANES_KEPT`` or older than ``PANE_DAYS``.
  const save = (pane: string, next: State) => {
    const now = Date.now();
    const all = { ...panes(), [pane]: { ...next, at: now } };
    const kept = Object.entries(all)
      .filter(([, value]) => typeof value?.at === "number" && now - value.at < PANE_DAYS * 86_400_000)
      .sort(([, a], [, b]) => (b.at as number) - (a.at as number))
      .slice(0, PANES_KEPT);
    write(INSPECTOR_PANES_KEY, JSON.stringify(Object.fromEntries(kept)));
  };

  let pane: string | undefined;
  let state: State | undefined;
  const listeners = new Set<() => void>();
  const current = (): State => (state ??= defaults());
  const update = (next: State, persist: boolean) => {
    if (persist && pane) save(pane, next);
    const changed = next !== state;
    state = next;
    if (changed) for (const listener of listeners) listener();
  };
  const subscribe = (listener: () => void) => {
    listeners.add(listener);
    return () => void listeners.delete(listener);
  };
  return {
    current,
    subscribe,
    /// The pane shows chat `sessionId` (a relaunch, a new chat's first session, another chat in the
    /// pane): it shows that chat's saved state, or keeps what it shows and saves it as the chat's.
    bind(sessionId: string | undefined) {
      if (!sessionId || sessionId === pane) return;
      pane = sessionId;
      const saved = own(sessionId);
      if (saved) update(saved, false);
      else save(sessionId, current());
    },
    setOpen(open: boolean) {
      write(OPEN_KEY, open ? "1" : "0");
      update({ ...current(), open }, true);
    },
    /// A drag's width; `save` stores it (at the drag's end, not on every step).
    setWidth(width: number, persist = true) {
      const next = clampWidth(width);
      if (persist) write(WIDTH_KEY, String(next));
      if (next !== current().width) update({ ...current(), width: next }, persist);
      else if (persist && pane) save(pane, current());
    },
    setSection(id: InspectorSectionId, open: boolean) {
      const sections = { ...current().sections, [id]: open };
      write(SECTIONS_KEY, JSON.stringify(sections));
      update({ ...current(), sections }, true);
    },
    /// Forgets every choice, every pane's too.
    reset() {
      for (const key of [OPEN_KEY, WIDTH_KEY, SECTIONS_KEY, INSPECTOR_PANES_KEY]) write(key, null);
      pane = undefined;
      state = undefined;
      update(defaults(), false);
    },
  };
}

/// This page's pane.
const page = createInspectorStore();

/// The live state.
export const useInspectorState = (): State => useSyncExternalStore(page.subscribe, page.current, page.current);
export const inspectorState = page.current;
/// Whether it is open, alone: a pane that needs only that is not drawn again on every drag step.
const openNow = () => page.current().open;
export const useInspectorOpen = (): boolean => useSyncExternalStore(page.subscribe, openNow, openNow);
/// Keys this pane's state by the chat it shows (useChatInspector, from the snapshot's session).
export const bindInspectorPane = page.bind;
export const setInspectorOpen = page.setOpen;
export const setInspectorWidth = page.setWidth;
export const setInspectorSection = page.setSection;
/// Forgets every choice: the gallery and the tests start each case on a clean slate.
export const resetInspectorState = page.reset;
