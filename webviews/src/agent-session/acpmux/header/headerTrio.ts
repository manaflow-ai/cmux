// The chat header's three top-right controls (top-right thunderdome D, Debug Settings
// `agentChat.headerControls`, CmuxNextAgentPane AgentPaneTunables+HeaderControls.swift). Leo, 2026-11-07:
// "The proposition of a 3-button only group is: 1. Ellipsis, for dealing with your current chat
// 2. Session info 3. The grouped "new everything" which ALSO has a preview when hovered over".
//
// `standard` is today's row. `trio` draws "...", the panel toggle and one New split button, in that
// order. The New button's face makes the last kind again in one click (a terminal stays one click for
// whoever makes terminals), the New Tab page the first time; its chevron lists every kind with a
// preview of where it opens. The quick actions the row no longer draws (Changes, Files, Preview,
// Split Down) wait in "..." and keep their shortcuts.

export type HeaderControls = "standard" | "trio";

const LAYOUTS: readonly HeaderControls[] = ["standard", "trio"];

/// The wire value as a layout, or undefined (the header state keeps the one it has).
export function readHeaderControls(value: unknown): HeaderControls | undefined {
  return LAYOUTS.includes(value as HeaderControls) ? (value as HeaderControls) : undefined;
}

/// What the New button makes: a terminal or a browser beside the chat, a side chat (a fork through
/// the last turn), or the New Tab page beside the chat, which starts a chat or opens anything else.
export type NewKind = "terminal" | "browser" | "sideChat" | "newTab";

export const NEW_KINDS: readonly NewKind[] = ["terminal", "browser", "sideChat", "newTab"];

/// The kinds a chat can make now, in the menu's order: a side chat needs a turn to fork.
export function newKinds(available: Partial<Record<NewKind, boolean>>): NewKind[] {
  return NEW_KINDS.filter((kind) => available[kind] !== false);
}

/// The kind a click on the New button's face makes: the last one made when it can still be made,
/// else the New Tab page, which offers every kind, else (a chat not started yet) a terminal.
export function repeatKind(last: NewKind | undefined, kinds: readonly NewKind[]): NewKind {
  if (last && kinds.includes(last)) return last;
  return kinds.includes("newTab") ? "newTab" : "terminal";
}

const LAST_KIND_KEY = "acpmux.header.newKind";

/// The last kind made from the New button, kept across chats and launches on this Mac.
export function readLastKind(storage: Pick<Storage, "getItem"> | undefined = safeStorage()): NewKind | undefined {
  const value = storage?.getItem(LAST_KIND_KEY);
  return NEW_KINDS.includes(value as NewKind) ? (value as NewKind) : undefined;
}

export function writeLastKind(kind: NewKind, storage: Pick<Storage, "setItem"> | undefined = safeStorage()): void {
  try {
    storage?.setItem(LAST_KIND_KEY, kind);
  } catch {
    // A full or blocked store only forgets the pick: the next click opens the New Tab page.
  }
}

function safeStorage(): Storage | undefined {
  try {
    return globalThis.localStorage;
  } catch {
    return undefined;
  }
}
