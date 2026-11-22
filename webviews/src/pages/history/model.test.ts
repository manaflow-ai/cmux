import { describe, expect, test } from "bun:test";
import {
  canOpen,
  filterKinds,
  flatten,
  groupEntries,
  groupTitle,
  HISTORY_FILTERS,
  localDayStart,
  menuItems,
  moveSelection,
  reconcileSelection,
  returnTarget,
  rowBadge,
  rowDetail,
  siteHost,
} from "./model";
import type { HistoryEntry } from "./types";

const HOUR = 3_600_000;
const noon = new Date(2026, 9, 4, 12, 0, 0).getTime();

function entry(id: string, patch: Partial<HistoryEntry> = {}): HistoryEntry {
  return { id, kind: "page", at_ms: noon, title: id, available: true, ...patch };
}

describe("filters", () => {
  test("each chip maps to one kind, All to none", () => {
    expect(HISTORY_FILTERS.map(filterKinds)).toEqual([[], ["page"], ["location"], ["command"], ["agent"], ["closed"]]);
  });
});

describe("grouping", () => {
  const entries = [
    entry("a", { at_ms: noon, workspace: "w1", machine: "mini" }),
    entry("b", { at_ms: noon - 2 * HOUR, workspace: "w2" }),
    entry("c", { at_ms: noon - 20 * HOUR, workspace: "w1", machine: "mini" }),
    entry("d", { at_ms: noon - 30 * HOUR }),
  ];

  test("day groups by local day, newest group first, order kept inside", () => {
    const groups = groupEntries(entries, "day");
    expect(groups.map((group) => group.entries.map((e) => e.id))).toEqual([
      ["a", "b"],
      ["c", "d"],
    ]);
    expect(groups[0].at_ms).toBe(localDayStart(noon));
    expect(groups[0].name).toBeUndefined();
  });

  test("workspace and machine group by name; missing names form one group", () => {
    expect(groupEntries(entries, "workspace").map((g) => [g.name, g.entries.map((e) => e.id)])).toEqual([
      ["w1", ["a", "c"]],
      ["w2", ["b"]],
      [undefined, ["d"]],
    ]);
    expect(groupEntries(entries, "machine").map((g) => [g.name, g.entries.length])).toEqual([
      ["mini", 2],
      [undefined, 2],
    ]);
  });

  test("grouping never adds or drops an entry", () => {
    for (const grouping of ["day", "workspace", "machine"] as const) {
      expect(
        flatten(groupEntries(entries, grouping))
          .map((e) => e.id)
          .sort(),
      ).toEqual(["a", "b", "c", "d"]);
    }
  });

  test("titles: relative day, full date, names and fallbacks", () => {
    const t = (key: string) => ({ "group.noWorkspace": "No Workspace", "group.thisMac": "This Mac" })[key] ?? key;
    const [today, yesterday] = groupEntries(entries, "day");
    expect(groupTitle(today, "day", t, "en", noon)).toBe("Today");
    expect(groupTitle(yesterday, "day", t, "en", noon)).toBe("Yesterday");
    const older = groupEntries([entry("x", { at_ms: noon - 5 * 24 * HOUR })], "day")[0];
    expect(groupTitle(older, "day", t, "en", noon)).toBe(
      new Intl.DateTimeFormat("en", { dateStyle: "full" }).format(older.at_ms),
    );
    expect(groupTitle({ id: "w", at_ms: 0, entries: [] }, "workspace", t, "en", noon)).toBe("No Workspace");
    expect(groupTitle({ id: "m", at_ms: 0, entries: [] }, "machine", t, "en", noon)).toBe("This Mac");
    expect(groupTitle({ id: "m", at_ms: 0, name: "mini", entries: [] }, "machine", t, "en", noon)).toBe("mini");
  });
});

describe("rows", () => {
  test("detail joins detail and machine", () => {
    expect(rowDetail(entry("a", { detail: "https://x", machine: "mini" }))).toBe("https://x · mini");
    expect(rowDetail(entry("a", { detail: "~/src" }))).toBe("~/src");
    expect(rowDetail(entry("a"))).toBeUndefined();
  });

  test("badges: offline wins, then current location, then running agent", () => {
    expect(rowBadge(entry("a", { available: false, kind: "agent", running: true }))).toBe("offline");
    expect(rowBadge(entry("a", { kind: "location", current: true }))).toBe("current");
    expect(rowBadge(entry("a", { kind: "agent", running: true }))).toBe("running");
    expect(rowBadge(entry("a", { kind: "page", current: true }))).toBeUndefined();
  });

  test("an offline entry or a command without text cannot open", () => {
    expect(canOpen(entry("a"))).toBe(true);
    expect(canOpen(entry("a", { available: false }))).toBe(false);
    expect(canOpen(entry("a", { kind: "command" }))).toBe(false);
    expect(canOpen(entry("a", { kind: "command", command: "ls" }))).toBe(true);
  });
});

describe("menus match the Swift page", () => {
  const labels = (e: HistoryEntry) => menuItems(e).map((item) => item.action.label);

  test("page", () => {
    const items = menuItems(entry("p", { url: "https://github.com/x" }));
    expect(items.map((i) => i.action.label)).toEqual([
      "menu.open",
      "menu.openInNewTab",
      "menu.copyURL",
      "menu.removeSite",
      "menu.remove",
    ]);
    expect(items[3]).toMatchObject({ destructive: true, separatorBefore: true });
    expect(items[2].action).toEqual({ kind: "copy", label: "menu.copyURL", text: "https://github.com/x" });
  });

  test("location, closed, agent, command", () => {
    expect(labels(entry("l", { kind: "location" }))).toEqual(["menu.goTo", "menu.remove"]);
    expect(labels(entry("c", { kind: "closed" }))).toEqual(["menu.reopen", "menu.remove"]);
    expect(labels(entry("c", { kind: "closed", url: "https://x" }))).toEqual([
      "menu.reopen",
      "menu.copyURL",
      "menu.remove",
    ]);
    expect(labels(entry("g", { kind: "agent", session_id: "s1" }))).toEqual([
      "menu.resume",
      "menu.copySessionID",
      "menu.remove",
    ]);
    expect(labels(entry("m", { kind: "command", command: "ls" }))).toEqual([
      "menu.runAgain",
      "menu.copyCommand",
      "menu.remove",
    ]);
    expect(labels(entry("m", { kind: "command" }))).toEqual(["menu.remove"]);
  });

  test("remove is always last and destructive", () => {
    const last = menuItems(entry("l", { kind: "location" })).at(-1);
    expect(last).toMatchObject({ action: { kind: "remove" }, destructive: true });
  });

  test("site host only for page URLs", () => {
    expect(siteHost(entry("p", { url: "https://docs.rs/serde" }))).toBe("docs.rs");
    expect(siteHost(entry("p", { url: "not a url" }))).toBeUndefined();
    expect(siteHost(entry("c", { kind: "closed", url: "https://docs.rs" }))).toBeUndefined();
  });
});

describe("selection", () => {
  const flat = [entry("a"), entry("b"), entry("c")];

  test("down from nothing selects the first, up from nothing the last", () => {
    expect(moveSelection(flat, undefined, 1)).toBe("a");
    expect(moveSelection(flat, undefined, -1)).toBe("c");
  });

  test("moves clamp at both ends", () => {
    expect(moveSelection(flat, "a", -1)).toBe("a");
    expect(moveSelection(flat, "c", 1)).toBe("c");
    expect(moveSelection(flat, "a", 2)).toBe("c");
    expect(moveSelection([], "a", 1)).toBe("a");
  });

  test("a removed selection moves to the first entry; none stays none", () => {
    expect(reconcileSelection(flat, "b")).toBe("b");
    expect(reconcileSelection(flat, "zz")).toBe("a");
    expect(reconcileSelection(flat, undefined)).toBeUndefined();
    expect(reconcileSelection([], "a")).toBeUndefined();
  });

  test("Return opens the selection, else the first row", () => {
    expect(returnTarget(flat, "b")?.id).toBe("b");
    expect(returnTarget(flat, undefined)?.id).toBe("a");
    expect(returnTarget([], undefined)).toBeUndefined();
  });
});
