// Pure presentation model of the History page (plans/cmux-next/react-pages.md 2.4): filter chips,
// grouping, row text, row menus, selection. The provider filters entries (kinds, search tokens,
// range); the page groups and presents them. Behavior matches the Swift page it replaces
// (CmuxNextHistory/HistoryPageModel.swift, HistoryQuery.swift HistoryGrouping, HistoryPageRow.swift).
import type { HistoryEntry, HistoryKind, HistoryRange } from "./types";

export type HistoryFilter = "all" | "pages" | "locations" | "commands" | "agents" | "closed";

export const HISTORY_FILTERS: readonly HistoryFilter[] = ["all", "pages", "locations", "commands", "agents", "closed"];

export type HistoryGrouping = "day" | "workspace" | "machine";

export const HISTORY_GROUPINGS: readonly HistoryGrouping[] = ["day", "workspace", "machine"];

/** The Swift page loads at most this many entries. */
export const PAGE_LIMIT = 1000;

export function filterKinds(filter: HistoryFilter): HistoryKind[] {
  switch (filter) {
    case "all":
      return [];
    case "pages":
      return ["page"];
    case "locations":
      return ["location"];
    case "commands":
      return ["command"];
    case "agents":
      return ["agent"];
    case "closed":
      return ["closed"];
  }
}

export interface HistoryGroup {
  id: string;
  /** The local day's start for `day`, else the newest entry's time. */
  at_ms: number;
  /** The workspace or machine name; absent for `day` and for entries without one. */
  name?: string;
  entries: HistoryEntry[];
}

/** Start of the local day that contains `ms`. */
export function localDayStart(ms: number): number {
  const date = new Date(ms);
  return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
}

/**
 * Groups entries (already newest first), keeping their order inside each group; groups are
 * ordered by their newest entry.
 */
export function groupEntries(entries: readonly HistoryEntry[], grouping: HistoryGrouping): HistoryGroup[] {
  const groups = new Map<string, HistoryGroup>();
  for (const entry of entries) {
    let key: string;
    let at = entry.at_ms;
    let name: string | undefined;
    switch (grouping) {
      case "day":
        at = localDayStart(entry.at_ms);
        key = `day:${at}`;
        break;
      case "workspace":
        name = entry.workspace || undefined;
        key = `workspace:${name ?? ""}`;
        break;
      case "machine":
        name = entry.machine || undefined;
        key = `machine:${name ?? ""}`;
        break;
    }
    let group = groups.get(key);
    if (!group) {
      group = { id: key, at_ms: at, name, entries: [] };
      groups.set(key, group);
    }
    group.entries.push(entry);
  }
  return [...groups.values()];
}

export function flatten(groups: readonly HistoryGroup[]): HistoryEntry[] {
  return groups.flatMap((group) => group.entries);
}

/** "detail · machine", or undefined when the entry has neither. */
export function rowDetail(entry: HistoryEntry): string | undefined {
  const parts = [entry.detail, entry.machine].filter((part): part is string => !!part);
  return parts.length ? parts.join(" · ") : undefined;
}

export type RowBadge = "offline" | "current" | "running";

export function rowBadge(entry: HistoryEntry): RowBadge | undefined {
  if (!entry.available) return "offline";
  if (entry.kind === "location" && entry.current) return "current";
  if (entry.kind === "agent" && entry.running) return "running";
  return undefined;
}

export type MenuAction =
  | { kind: "open"; label: string; newTab: boolean }
  | { kind: "copy"; label: string; text: string }
  | { kind: "removeSite"; label: string }
  | { kind: "remove"; label: string };

export interface MenuItem {
  action: MenuAction;
  destructive: boolean;
  separatorBefore: boolean;
}

/** String keys of the History table (CmuxNextHistory/Resources/Localizable.xcstrings). */
export const MenuLabel = {
  open: "menu.open",
  openInNewTab: "menu.openInNewTab",
  copyURL: "menu.copyURL",
  removeSite: "menu.removeSite",
  goTo: "menu.goTo",
  reopen: "menu.reopen",
  resume: "menu.resume",
  copySessionID: "menu.copySessionID",
  runAgain: "menu.runAgain",
  copyCommand: "menu.copyCommand",
  remove: "menu.remove",
} as const;

/** The row's context menu, by kind (Swift `HistoryPageMenu`). Labels are string keys. */
export function menuItems(entry: HistoryEntry): MenuItem[] {
  const items: MenuItem[] = [];
  const add = (action: MenuAction, destructive = false, separatorBefore = false) =>
    items.push({ action, destructive, separatorBefore });
  switch (entry.kind) {
    case "page":
      add({ kind: "open", label: MenuLabel.open, newTab: false });
      add({ kind: "open", label: MenuLabel.openInNewTab, newTab: true });
      if (entry.url) add({ kind: "copy", label: MenuLabel.copyURL, text: entry.url });
      add({ kind: "removeSite", label: MenuLabel.removeSite }, true, true);
      break;
    case "location":
      add({ kind: "open", label: MenuLabel.goTo, newTab: false });
      break;
    case "closed":
      add({ kind: "open", label: MenuLabel.reopen, newTab: false });
      if (entry.url) add({ kind: "copy", label: MenuLabel.copyURL, text: entry.url });
      break;
    case "agent":
      add({ kind: "open", label: MenuLabel.resume, newTab: false });
      if (entry.session_id) add({ kind: "copy", label: MenuLabel.copySessionID, text: entry.session_id });
      break;
    case "command":
      if (entry.command) {
        add({ kind: "open", label: MenuLabel.runAgain, newTab: false });
        add({ kind: "copy", label: MenuLabel.copyCommand, text: entry.command });
      }
      break;
  }
  add({ kind: "remove", label: MenuLabel.remove }, true);
  return items;
}

/** The host of a page entry's URL, for "Remove All from This Site". */
export function siteHost(entry: HistoryEntry): string | undefined {
  if (entry.kind !== "page" || !entry.url) return undefined;
  try {
    return new URL(entry.url).hostname || undefined;
  } catch {
    return undefined;
  }
}

/** Moves the selection by `offset` rows (Swift `moveSelection`). */
export function moveSelection(
  flat: readonly HistoryEntry[],
  selection: string | undefined,
  offset: number,
): string | undefined {
  if (!flat.length) return selection;
  let index = flat.findIndex((entry) => entry.id === selection);
  if (index < 0) index = offset > 0 ? -1 : flat.length;
  return flat[Math.max(0, Math.min(flat.length - 1, index + offset))].id;
}

/** After a reload: a selection whose entry is gone moves to the first entry. */
export function reconcileSelection(
  entries: readonly HistoryEntry[],
  selection: string | undefined,
): string | undefined {
  if (selection === undefined) return undefined;
  return entries.some((entry) => entry.id === selection) ? selection : entries[0]?.id;
}

/** The entry Return opens: the selection, else the first row. */
export function returnTarget(flat: readonly HistoryEntry[], selection: string | undefined): HistoryEntry | undefined {
  return flat.find((entry) => entry.id === selection) ?? flat[0];
}

/** Whether the row's primary action can run (Swift: restore refused while the machine is offline). */
export function canOpen(entry: HistoryEntry): boolean {
  return entry.available && (entry.kind !== "command" || !!entry.command);
}

export const FilterLabel: Record<HistoryFilter, string> = {
  all: "filter.all",
  pages: "filter.pages",
  locations: "filter.locations",
  commands: "filter.commands",
  agents: "filter.agents",
  closed: "filter.closed",
};

export const GroupingLabel: Record<HistoryGrouping, string> = {
  day: "group.day",
  workspace: "group.workspace",
  machine: "group.machine",
};

export const RangeLabel: Record<HistoryRange, string> = {
  hour: "range.hour",
  today: "range.today",
  week: "range.week",
  month: "range.month",
  all: "range.all",
};

export const BadgeLabel: Record<RowBadge, string> = {
  offline: "row.offline",
  current: "row.current",
  running: "row.running",
};

/**
 * A group header: relative day ("Today", "Yesterday") or the full date for `day`; the name, else
 * "No Workspace" / "This Mac".
 */
export function groupTitle(
  group: HistoryGroup,
  grouping: HistoryGrouping,
  t: (key: string) => string,
  language: string,
  nowMs: number,
): string {
  if (grouping === "workspace") return group.name ?? t("group.noWorkspace");
  if (grouping === "machine") return group.name ?? t("group.thisMac");
  const days = Math.round((localDayStart(nowMs) - group.at_ms) / 86_400_000);
  if (days === 0 || days === 1) {
    const text = new Intl.RelativeTimeFormat(language, { numeric: "auto" }).format(-days, "day");
    return text.charAt(0).toLocaleUpperCase(language) + text.slice(1);
  }
  return new Intl.DateTimeFormat(language, { dateStyle: "full" }).format(group.at_ms);
}

export function rowTime(entry: HistoryEntry, language: string): string {
  return new Intl.DateTimeFormat(language, { timeStyle: "short" }).format(entry.at_ms);
}
