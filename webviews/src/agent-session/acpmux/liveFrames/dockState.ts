// The preview window's state: where it floats, how big it is, and whether it is open, a pill,
// filling the pane or hidden. Pure, so the pointer handlers in FramesDock.tsx only dispatch.
// Persisted per pane in localStorage (`loadDock`, `saveDock`).

export type DockMode = "open" | "pill" | "full" | "hidden";
export type DockState = { x: number; y: number; width: number; height: number; mode: DockMode };
export type Bounds = { width: number; height: number };

export const MIN_WIDTH = 180;
export const MIN_HEIGHT = 120;
export const PILL_WIDTH = 132;
export const PILL_HEIGHT = 32;
const MARGIN = 12;

export const initialDock = (pane: Bounds): DockState => {
  const width = Math.min(320, Math.max(MIN_WIDTH, Math.round(pane.width * 0.4)));
  const height = Math.round((width * 3) / 4);
  return {
    x: Math.max(0, pane.width - width - MARGIN),
    y: Math.max(0, pane.height - height - 140),
    width,
    height,
    mode: "open",
  };
};

export type DockEvent =
  | { type: "move"; dx: number; dy: number; pane: Bounds }
  | { type: "resize"; dw: number; dh: number; pane: Bounds }
  | { type: "mode"; mode: DockMode }
  /// The pane changed size: keep the window inside it.
  | { type: "fit"; pane: Bounds };

const clamp = (value: number, low: number, high: number) => Math.min(Math.max(value, low), Math.max(low, high));

/// The window's box as drawn (a pill is its own small box at the same corner).
export const shownSize = (dock: DockState): { width: number; height: number } =>
  dock.mode === "pill" ? { width: PILL_WIDTH, height: PILL_HEIGHT } : { width: dock.width, height: dock.height };

export function dockReducer(dock: DockState, event: DockEvent): DockState {
  switch (event.type) {
    case "move": {
      const size = shownSize(dock);
      return {
        ...dock,
        x: clamp(dock.x + event.dx, 0, event.pane.width - size.width),
        y: clamp(dock.y + event.dy, 0, event.pane.height - size.height),
      };
    }
    case "resize": {
      const width = clamp(dock.width + event.dw, MIN_WIDTH, event.pane.width - dock.x);
      const height = clamp(dock.height + event.dh, MIN_HEIGHT, event.pane.height - dock.y);
      return { ...dock, width, height };
    }
    case "mode":
      // Expanding twice, or collapsing a pill, returns to the window.
      return { ...dock, mode: event.mode };
    case "fit": {
      const width = clamp(dock.width, MIN_WIDTH, event.pane.width);
      const height = clamp(dock.height, MIN_HEIGHT, event.pane.height);
      return {
        ...dock,
        width,
        height,
        x: clamp(dock.x, 0, event.pane.width - width),
        y: clamp(dock.y, 0, event.pane.height - height),
      };
    }
  }
}

const key = (pane: string) => `cmux.agentPane.framesDock.${pane}`;
const MODES: readonly DockMode[] = ["open", "pill", "full", "hidden"];

/// The saved state of pane `pane`, or undefined when none is saved or it is not a window.
export function parseDock(raw: string | null): DockState | undefined {
  if (!raw) return undefined;
  try {
    const value = JSON.parse(raw) as Partial<DockState>;
    const ok = (n: unknown): n is number => typeof n === "number" && Number.isFinite(n);
    if (!ok(value.x) || !ok(value.y) || !ok(value.width) || !ok(value.height)) return undefined;
    if (!MODES.includes(value.mode as DockMode)) return undefined;
    return { x: value.x, y: value.y, width: value.width, height: value.height, mode: value.mode as DockMode };
  } catch {
    return undefined;
  }
}

export function loadDock(pane: string, storage: Pick<Storage, "getItem"> | undefined = safeStorage()) {
  try {
    return parseDock(storage?.getItem(key(pane)) ?? null);
  } catch {
    return undefined;
  }
}

export function saveDock(pane: string, dock: DockState, storage: Pick<Storage, "setItem"> | undefined = safeStorage()) {
  try {
    storage?.setItem(key(pane), JSON.stringify(dock));
  } catch {
    // Storage full or blocked: the window just forgets its place.
  }
}

function safeStorage(): Storage | undefined {
  try {
    return typeof localStorage === "undefined" ? undefined : localStorage;
  } catch {
    return undefined;
  }
}

/// What names a pane's saved window: the host's pane id when the page URL carries one, else the
/// chat it shows (a pane that moves between chats keeps its place with the chat it was set on).
export function framesPaneKey(sessionId: string | undefined, search = safeSearch()): string {
  const params = new URLSearchParams(search);
  return params.get("pane") ?? params.get("panel") ?? params.get("tab") ?? sessionId ?? "default";
}

function safeSearch(): string {
  try {
    return typeof location === "undefined" ? "" : location.search;
  } catch {
    return "";
  }
}
