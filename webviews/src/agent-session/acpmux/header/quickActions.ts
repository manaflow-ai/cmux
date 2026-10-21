import { useSyncExternalStore } from "react";

/// The chat header's quick actions (the buttons left of the Sources summary and "..." menu): which ones show,
/// in which order, and whether each one toggles its panel or opens another copy. This is the one model
/// the header reads (ChatHeaderTools). The default copies T3 Chat and ChatGPT: every button toggles,
/// so a second click closes what the first one opened. By default only the most-used show (Changes,
/// Terminal, Browser; Leo 2026-10-12: about four buttons with "..."), and Browser opens the chat's
/// local page when it has one (Leo 2026-10-20: one globe, not a play button beside it): Preview,
/// [+] New tab, Files and Split Down stay off until the person shows them here; New tab, Files and
/// Split Down fold into the top of the "..." chat menu meanwhile, each while it applies.
///
/// The user customizes it in `agent-pane/layout.json` next to `cmux.json` (the file the App watches and
/// pushes through `applyCustomization`):
///
///     {"quickActions": [{"id": "terminal", "mode": "open"}, "browser"]}
///
/// A bare id takes the default mode. Unknown ids and repeats are dropped; `[]` shows no quick actions;
/// a missing or malformed list keeps the default.
///
/// The page decides nothing about a split: Terminal, Browser and Changes send their mode with the app
/// action (`pane.action {id, mode}`), and the App opens the panel or closes the one this button opened
/// (CmuxNextApp AgentChatSplitToggles). Changes owns the diff viewer of the chat's folder, beside it as
/// an agent's diff (cx-00n1, Claude Code desktop's diff toggle); it shows only while the chat has changes
/// or its diff is open (hidden, not disabled, cx-qom0). The last turn's changes are also in Sources.
/// Preview owns a browser tab beside the chat on the local page the chat's last turn started or
/// mentioned (its preview card's address); it shows only while there is one or its page is open.
///
/// Split Down owns a terminal under the chat (cx-kk7lm): with Terminal, the chat's Split Right, it is
/// the Split Right and Split Down every pane's toolbar has.
///
/// Files owns a tree of the chat's folder beside it (cx-p4rt).
///
/// `newTab` is ChatGPT's [+] New tab: it opens a New Tab page in a column right of the chat, and the
/// same button then reads Hide tabs, which hides the panes beside the chat (the App zooms the chat,
/// closing nothing) and shows them again. It always toggles; its mode is ignored.

export type QuickActionId = "terminal" | "splitDown" | "browser" | "changes" | "files" | "preview" | "newTab";
/// `toggle`: a second click closes the split the first one opened. `open`: every click opens another.
export type QuickActionMode = "toggle" | "open";
export interface QuickAction {
  readonly id: QuickActionId;
  readonly mode: QuickActionMode;
}

const ids: readonly QuickActionId[] = ["changes", "preview", "terminal", "splitDown", "browser", "files", "newTab"];
/// Not shown until a person adds them (in the chat menu meanwhile).
/// Preview too (Leo 2026-10-20, "these buttons are kind of weird"): Browser opens the chat's page when it has one.
const OFF_BY_DEFAULT: ReadonlySet<QuickActionId> = new Set(["preview", "newTab", "files", "splitDown"]);
const isId = (value: unknown): value is QuickActionId => ids.includes(value as QuickActionId);
const isMode = (value: unknown): value is QuickActionMode => value === "toggle" || value === "open";

export const QUICK_ACTION_DEFAULTS: readonly QuickAction[] = ids
  .filter((id) => !OFF_BY_DEFAULT.has(id))
  .map((id) => ({ id, mode: "toggle" }));

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

/// The quick action list now.
export const quickActions = (): readonly QuickAction[] => current;

/// The live quick action list.
export const useQuickActions = (): readonly QuickAction[] => useSyncExternalStore(subscribe, snapshot, snapshot);

/// Every quick action, in the default order (the right-click menu lists them all).
export const QUICK_ACTION_IDS: readonly QuickActionId[] = ids;

/// `list` with `id` shown or hidden. A shown one takes its default place among the ones shown,
/// in its default mode.
export function withShown(list: readonly QuickAction[], id: QuickActionId, shown: boolean): readonly QuickAction[] {
  if (!shown) return list.filter((action) => action.id !== id);
  if (list.some((action) => action.id === id)) return list;
  const rank = ids.indexOf(id);
  const at = list.findIndex((action) => ids.indexOf(action.id) > rank);
  const next = [...list];
  next.splice(at < 0 ? next.length : at, 0, { id, mode: "toggle" });
  return next;
}

/// `list` with `id` moved one place left (`-1`) or right (`1`); unchanged at either end.
export function withMoved(list: readonly QuickAction[], id: QuickActionId, by: -1 | 1): readonly QuickAction[] {
  const from = list.findIndex((action) => action.id === id);
  const to = from + by;
  if (from < 0 || to < 0 || to >= list.length) return list;
  const next = [...list];
  [next[from], next[to]] = [next[to], next[from]];
  return next;
}

/// `list` with `id` toggling its panel or opening another on each click.
export function withMode(
  list: readonly QuickAction[],
  id: QuickActionId,
  mode: QuickActionMode,
): readonly QuickAction[] {
  return list.map((action) => (action.id === id ? { id, mode } : action));
}
