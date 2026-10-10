import { useSyncExternalStore } from "react";

/// The chat header's quick actions (the buttons left of the Sources summary and "..." menu): which ones show,
/// in which order, and whether each one toggles its panel or opens another copy. This is the one model
/// the header reads (ChatHeaderTools). The default copies T3 Chat and ChatGPT: every button toggles,
/// so a second click closes what the first one opened.
///
/// The user customizes it in `agent-pane/layout.json` next to `cmux.json` (the file the App watches and
/// pushes through `applyCustomization`):
///
///     {"quickActions": [{"id": "terminal", "mode": "open"}, "browser"]}
///
/// A bare id takes the default mode. Unknown ids and repeats are dropped; `[]` shows no quick actions;
/// a missing or malformed list keeps the default.
///
/// The page decides nothing about a split: Terminal and Browser send their mode with the app action
/// (`pane.action {id, mode}`), and the App opens the split or closes the one this button opened
/// (CmuxNextApp AgentChatSplitToggles). The last turn's changes live in the Sources popover, not here.

export type QuickActionId = "terminal" | "browser";
/// `toggle`: a second click closes the split the first one opened. `open`: every click opens another.
export type QuickActionMode = "toggle" | "open";
export interface QuickAction {
  readonly id: QuickActionId;
  readonly mode: QuickActionMode;
}

const ids: readonly QuickActionId[] = ["terminal", "browser"];
const isId = (value: unknown): value is QuickActionId => ids.includes(value as QuickActionId);
const isMode = (value: unknown): value is QuickActionMode => value === "toggle" || value === "open";

export const QUICK_ACTION_DEFAULTS: readonly QuickAction[] = ids.map((id) => ({ id, mode: "toggle" }));

/// `layout.quickActions` as the header's list, or the default when it is missing or not a list.
export function readQuickActions(layout: Record<string, unknown> | undefined): readonly QuickAction[] {
  const list = layout?.quickActions;
  if (!Array.isArray(list)) return QUICK_ACTION_DEFAULTS;
  const actions: QuickAction[] = [];
  for (const entry of list) {
    const raw = typeof entry === "string" ? { id: entry } : (entry as { id?: unknown; mode?: unknown } | null);
    if (!raw || !isId(raw.id) || actions.some((action) => action.id === raw.id)) continue;
    actions.push({ id: raw.id, mode: isMode(raw.mode) ? raw.mode : "toggle" });
  }
  return actions;
}

let current: readonly QuickAction[] = QUICK_ACTION_DEFAULTS;
const listeners = new Set<() => void>();

/// The host pushed `layout.json` (or `{}` when it was removed): the header follows at once.
export function configureQuickActions(layout: Record<string, unknown> | undefined): void {
  const next = readQuickActions(layout);
  if (JSON.stringify(next) === JSON.stringify(current)) return;
  current = next;
  for (const listener of listeners) listener();
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const snapshot = () => current;

/// The live quick action list.
export const useQuickActions = (): readonly QuickAction[] => useSyncExternalStore(subscribe, snapshot, snapshot);
