import { describe, expect, test } from "bun:test";
import {
  displayStrokes,
  filterBindings,
  identity,
  isReadOnly,
  keyMatches,
  moveSelection,
  normalizeWhen,
  reconcileSelection,
  resettableCommands,
  SourceLabel,
  sourceLabel,
  sortBindings,
} from "./model";
import type { Binding } from "./types";

let nextId = 0;
function binding(patch: Partial<Binding> & Pick<Binding, "command" | "key">): Binding {
  return {
    id: nextId++,
    display: patch.key.toUpperCase(),
    title: patch.command,
    when: null,
    source: "default",
    conflicts: [],
    ...patch,
  };
}

const table = [
  binding({ command: "tab.new", title: "New Tab", key: "cmd+t", display: "⌘T" }),
  binding({ command: "keys.open", title: "Open Keyboard Shortcuts", key: "cmd+k cmd+s", display: "⌘K ⌘S" }),
  binding({ command: "split.down", title: "Split Down", key: "cmd+k cmd+d", display: "⌘K ⌘D", source: "user" }),
  binding({ command: "palette.open", title: "Open Command Palette", key: "cmd+shift+p", conflicts: [4] }),
  binding({ command: "history.open", title: "Show History", key: "cmd+shift+p", when: "a", conflicts: [3] }),
  binding({ command: "split.right", title: "Split Right", key: "cmd+d", removed: true }),
  binding({ command: "new.window", title: "new window", key: "cmd+shift+n" }),
];

describe("keybindings model", () => {
  test("sort is by title (case-insensitive), then key", () => {
    const twin = binding({ command: "tab.new", title: "New Tab", key: "cmd+n" });
    expect(sortBindings([...table, twin]).map((b) => `${b.title}|${b.key}`)).toEqual([
      "New Tab|cmd+n",
      "New Tab|cmd+t",
      "new window|cmd+shift+n",
      "Open Command Palette|cmd+shift+p",
      "Open Keyboard Shortcuts|cmd+k cmd+s",
      "Show History|cmd+shift+p",
      "Split Down|cmd+k cmd+d",
      "Split Right|cmd+d",
    ]);
  });

  test("search matches title, command id, key text or display, case-insensitive", () => {
    const find = (text: string) => filterBindings(table, { text, conflictsOnly: false }).map((b) => b.command);
    expect(find("SPLIT")).toEqual(["split.down", "split.right"]);
    expect(find("history.")).toEqual(["history.open"]);
    expect(find("cmd+k")).toEqual(["keys.open", "split.down"]);
    expect(find("⌘k ⌘s")).toEqual(["keys.open"]);
    expect(find("  ")).toHaveLength(table.length);
  });

  test("conflicts only keeps active entries with conflicts", () => {
    expect(filterBindings(table, { text: "", conflictsOnly: true }).map((b) => b.command)).toEqual([
      "palette.open",
      "history.open",
    ]);
  });

  test("recorded strokes filter by whole-stroke key prefix", () => {
    const prefix = (key: string) =>
      filterBindings(table, { text: key, keyFilter: { key, exact: false }, conflictsOnly: false }).map(
        (b) => b.command,
      );
    expect(prefix("cmd+k")).toEqual(["keys.open", "split.down"]);
    expect(prefix("CMD+K  cmd+s")).toEqual(["keys.open"]);
    // "cmd+d" is a stroke of its own, not a text prefix of "cmd+k cmd+d".
    expect(prefix("cmd+d")).toEqual(["split.right"]);
    expect(prefix("cmd+shift")).toEqual([]);
  });

  test("an exact key filter shows every entry on the same keys", () => {
    const filter = { key: "cmd+shift+p", exact: true };
    expect(keyMatches("cmd+shift+p", filter)).toBe(true);
    expect(keyMatches("cmd+shift+p x", filter)).toBe(false);
    expect(filterBindings(table, { text: "", keyFilter: filter, conflictsOnly: false })).toHaveLength(2);
  });

  test("reset applies to commands with a user entry or a removed default", () => {
    expect([...resettableCommands(table)].sort()).toEqual(["split.down", "split.right"]);
  });

  test("Up/Down move the selection inside the shown rows", () => {
    const rows = table.slice(0, 3);
    expect(moveSelection(rows, undefined, 1)).toBe(identity(rows[0]));
    expect(moveSelection(rows, undefined, -1)).toBe(identity(rows[2]));
    expect(moveSelection(rows, identity(rows[0]), 1)).toBe(identity(rows[1]));
    expect(moveSelection(rows, identity(rows[2]), 1)).toBe(identity(rows[2]));
    expect(moveSelection([], "x", 1)).toBe("x");
    expect(reconcileSelection(rows, identity(table[5]))).toBeUndefined();
    expect(reconcileSelection(rows, identity(rows[1]))).toBe(identity(rows[1]));
  });

  test("identity tells a removed default from its active form, and blank when is null", () => {
    const active = { ...table[5], removed: undefined };
    expect(identity(active)).not.toBe(identity(table[5]));
    expect(normalizeWhen("  ")).toBeNull();
    expect(normalizeWhen(" a && b ")).toBe("a && b");
    expect(displayStrokes(" ⌘K  ⌘S ")).toEqual(["⌘K", "⌘S"]);
  });
  test("Ghostty rows have their own source labels and are read-only (GHOSTTY-CONFIG)", () => {
    expect(SourceLabel.ghostty).toBe("keybindings.page.source.ghostty");
    expect(SourceLabel["ghostty-fallback"]).toBe("keybindings.page.source.ghosttyDefault");
    expect(isReadOnly(binding({ command: "splitDown", key: "cmd+d", source: "ghostty" }))).toBe(true);
    expect(isReadOnly(binding({ command: "nextSurface", key: "cmd+shift+]", source: "ghostty-fallback" }))).toBe(true);
    expect(isReadOnly(binding({ command: "tab.new", key: "cmd+t", removed: true }))).toBe(true);
    expect(isReadOnly(binding({ command: "tab.new", key: "cmd+t" }))).toBe(false);
  });
  test("a default the Ghostty config claims says so and has no Reset (PANE-FOCUS-RESIZE-KEYS-AND-GHOSTTY-KEYBINDS)", () => {
    const claimed = binding({ command: "resizePaneLeft", key: "ctrl+shift+h", removed: true, removedBy: "ghostty" });
    expect(sourceLabel(claimed)).toBe("keybindings.page.source.removedByGhostty");
    expect(sourceLabel(binding({ command: "tab.new", key: "cmd+t", removed: true }))).toBe("keybindings.page.source.removed");
    expect(sourceLabel(binding({ command: "tab.new", key: "cmd+t" }))).toBe("keybindings.page.source.default");
    expect(isReadOnly(claimed)).toBe(true);
    expect(resettableCommands([claimed]).size).toBe(0);
  });
});
