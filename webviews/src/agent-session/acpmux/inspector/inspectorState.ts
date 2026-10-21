// The Inspector's per-viewer state (ChatInspector.tsx): whether it is open, how wide it is, and which
// of its sections are folded. Every chat pane reads the same values, so the Inspector stays open
// across tabs until it is toggled off (Leo, 2026-10-20), and a resize or a fold in one tab shows in
// the next. They live in localStorage, kept in step across panes by the `storage` event; with no
// storage (a private window, a test) the page's own copy holds them.
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

const OPEN_KEY = "cmux.agentPane.inspector.open";
const WIDTH_KEY = "cmux.agentPane.inspector.width";
const SECTIONS_KEY = "cmux.agentPane.inspector.sections";
const KEYS = new Set([OPEN_KEY, WIDTH_KEY, SECTIONS_KEY]);

type State = { readonly open: boolean; readonly width: number; readonly sections: InspectorSections };

const clampWidth = (width: number) => Math.round(Math.min(INSPECTOR_WIDTH.max, Math.max(INSPECTOR_WIDTH.min, width)));

function read(key: string): string | null {
  try {
    return globalThis.localStorage?.getItem(key) ?? null;
  } catch {
    return null;
  }
}

function write(key: string, value: string | null) {
  try {
    if (value === null) globalThis.localStorage?.removeItem(key);
    else globalThis.localStorage?.setItem(key, value);
  } catch {
    // Storage off: the page's copy still holds it.
  }
}

function sectionsOf(raw: string | null): InspectorSections {
  try {
    const value: unknown = raw ? JSON.parse(raw) : undefined;
    if (!value || typeof value !== "object") return DEFAULT_SECTIONS;
    const stored = value as Partial<Record<InspectorSectionId, unknown>>;
    const sections = { ...DEFAULT_SECTIONS };
    for (const id of Object.keys(DEFAULT_SECTIONS) as InspectorSectionId[])
      if (typeof stored[id] === "boolean") sections[id] = stored[id];
    return sections;
  } catch {
    return DEFAULT_SECTIONS;
  }
}

/// Open unless the viewer closed it: a first chat shows it.
function load(): State {
  const width = Number(read(WIDTH_KEY));
  return {
    open: read(OPEN_KEY) !== "0",
    width: Number.isFinite(width) && width > 0 ? clampWidth(width) : INSPECTOR_WIDTH.fallback,
    sections: sectionsOf(read(SECTIONS_KEY)),
  };
}

let state: State | undefined;
const listeners = new Set<() => void>();
const current = (): State => (state ??= load());

function update(next: State) {
  state = next;
  for (const listener of listeners) listener();
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  // Another pane changed it: read it again.
  const storage = (event: StorageEvent) => {
    if (event.key !== null && !KEYS.has(event.key)) return;
    state = undefined;
    listener();
  };
  globalThis.addEventListener?.("storage", storage);
  return () => {
    listeners.delete(listener);
    globalThis.removeEventListener?.("storage", storage);
  };
};

/// The live state.
export const useInspectorState = (): State => useSyncExternalStore(subscribe, current, current);
export const inspectorState = current;
/// Whether it is open, alone: a pane that needs only that is not drawn again on every drag step.
const openNow = () => current().open;
export const useInspectorOpen = (): boolean => useSyncExternalStore(subscribe, openNow, openNow);

export function setInspectorOpen(open: boolean) {
  write(OPEN_KEY, open ? "1" : "0");
  update({ ...current(), open });
}

/// A drag's width; `save` stores it (at the drag's end, not on every step).
export function setInspectorWidth(width: number, save = true) {
  const next = clampWidth(width);
  if (save) write(WIDTH_KEY, String(next));
  if (next !== current().width) update({ ...current(), width: next });
}

export function setInspectorSection(id: InspectorSectionId, open: boolean) {
  const sections = { ...current().sections, [id]: open };
  write(SECTIONS_KEY, JSON.stringify(sections));
  update({ ...current(), sections });
}

/// Forgets every choice: the gallery and the tests start each case on a clean slate.
export function resetInspectorState() {
  for (const key of KEYS) write(key, null);
  update(load());
}
