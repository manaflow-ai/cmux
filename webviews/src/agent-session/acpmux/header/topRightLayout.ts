// The chat header's top-right layouts (Debug Settings `agentChat.topRight.consolidate`,
// CmuxNextAgentPane AgentPaneTopRightLayout): the top-right thunderdome's consolidate-and-morph
// direction (Leo 2026-11-05: "the top right icons and what they do and when they appear"). The
// pure part: which layout the App asked for, which panes this chat opened most recently, the
// glyph the morph control wears, and the dock's sections. TopRightLayouts.tsx draws them.
import type { HeaderQuickTool } from "./headerQuickTools";
import type { QuickActionId } from "./quickActions";

/// `row` is today's row of buttons; the rest replace it only while chosen.
export type TopRightLayout = "row" | "morph" | "tabStrip" | "dock";

export const TOP_RIGHT_LAYOUTS: readonly TopRightLayout[] = ["row", "morph", "tabStrip", "dock"];

/// The App's value, or undefined for anything else (an older App sends none: the page keeps its own).
export function readTopRightLayout(value: unknown): TopRightLayout | undefined {
  return TOP_RIGHT_LAYOUTS.find((layout) => layout === value);
}

/// How many panes the dock remembers.
const RECENT_LIMIT = 6;

let recent: readonly QuickActionId[] = [];
const listeners = new Set<() => void>();

/// The panes this chat's header opened, most recent first (one page is one chat).
export const recentPanes = (): readonly QuickActionId[] => recent;

export function subscribeRecentPanes(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/// A header pick ran `id`: it moves to the front.
export function notePaneOpened(id: QuickActionId): void {
  const next = [id, ...recent.filter((other) => other !== id)].slice(0, RECENT_LIMIT);
  if (next.join() === recent.join()) return;
  recent = next;
  for (const listener of listeners) listener();
}

/// Tests and the gallery start from no history.
export function resetRecentPanes(ids: readonly QuickActionId[] = []): void {
  recent = ids.slice(0, RECENT_LIMIT);
  for (const listener of listeners) listener();
}

/// The open panes (pressed tools), the most recently picked first; a pane opened some other way
/// (its own tab, a shortcut) follows in the header's order.
export function openTools(tools: readonly HeaderQuickTool[], order: readonly QuickActionId[]): HeaderQuickTool[] {
  const rank = (tool: HeaderQuickTool) => {
    const at = order.indexOf(tool.id);
    return at < 0 ? order.length + tools.indexOf(tool) : at;
  };
  return tools.filter((tool) => tool.pressed).sort((a, b) => rank(a) - rank(b));
}

/// The glyph the morph control wears: the pane picked last that is still open, else none (the
/// control's own glyph). The icon you click becomes the control, as it becomes the pane's tab.
export function morphFace(
  tools: readonly HeaderQuickTool[],
  order: readonly QuickActionId[],
): HeaderQuickTool | undefined {
  return openTools(tools, order)[0];
}

export interface DockSections {
  /// Open beside the chat now; a pick closes a toggle's pane, as its button does.
  open: HeaderQuickTool[];
  /// Opened from this header before and closed since, most recent first.
  recent: HeaderQuickTool[];
  /// Everything else, in the header's order.
  more: HeaderQuickTool[];
}

/// The dock's menu: open panes first, then recent ones, then the rest (a browser's recent tabs).
export function dockSections(tools: readonly HeaderQuickTool[], order: readonly QuickActionId[]): DockSections {
  const open = openTools(tools, order);
  const shown = new Set(open.map((tool) => tool.id));
  const recentTools = order.flatMap((id) => {
    const tool = tools.find((candidate) => candidate.id === id);
    return tool && !shown.has(id) ? [tool] : [];
  });
  for (const tool of recentTools) shown.add(tool.id);
  return { open, recent: recentTools, more: tools.filter((tool) => !shown.has(tool.id)) };
}
