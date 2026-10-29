import { expect, test } from "bun:test";
import {
  comboboxDescription,
  contextDescription,
  popoverDescription,
  popupAction,
  selectDescription,
  separatorId,
  textRow,
} from "./popupDescriptors";
test("select descriptors preserve stable choice ids and selection", () => {
  const d = selectDescription({
    label: "Theme",
    value: "dark",
    options: [
      { value: "system", label: "System", shortcut: "⌘0" },
      { value: "dark", label: "Dark" },
      { value: "light", label: "Light", disabled: true },
    ],
  });
  expect(d.title).toBe("Theme");
  expect(d.rows).toEqual([
    { id: "system", kind: "action", label: "System", shortcut: "⌘0", value: "system", checked: false },
    { id: "dark", kind: "action", label: "Dark", value: "dark", checked: true },
    { id: "light", kind: "action", label: "Light", value: "light", disabled: true, checked: false },
  ]);
});
test("combobox descriptors keep pinned actions at the end of keyboard order", () => {
  const d = comboboxDescription({
    suggestions: ["New project", "alpha", "beta"],
    pinnedSuggestions: ["New project"],
    query: "a",
    label: "Projects",
  });
  expect(d.search).toEqual({ id: "query", value: "a", placeholder: "Projects" });
  expect(d.rows.map((row) => row.value)).toEqual(["alpha", "beta", "New project"]);
  // Native `choice` means a segmented control with its own options. A suggestion is a
  // pickable action, with an optional checkmark for the committed selection.
  expect(d.rows.every((row) => row.kind === "action")).toBe(true);
});
test("combobox search IDs do not collide with suggestion IDs", () => {
  const suggestions = ["query", "query:search", "query:search:search"];
  const d = comboboxDescription({ suggestions });
  const ids = [d.search!.id, ...d.rows.map((row) => row.id)];
  expect(new Set(ids).size).toBe(ids.length);
  expect(d.rows.map((row) => row.value)).toEqual(suggestions);
  expect(d.search!.id).toBe(comboboxDescription({ suggestions: [] }).search!.id);
});
test("context descriptors preserve separators, toggles, and icon metadata", () => {
  const d = contextDescription([
    { id: "copy", label: "Copy", icon: "doc.on.doc" },
    { id: "wrap", label: "Wrap", checked: true, separatorBefore: true },
  ]);
  expect(d.rows).toEqual([
    { id: "copy", kind: "action", label: "Copy", icon: "doc.on.doc" },
    { id: separatorId("wrap"), kind: "separator", label: "" },
    { id: "wrap", kind: "action", label: "Wrap", checked: true },
  ]);
});

test("popover descriptors preserve caller row order without rendering elements", () => {
  expect(
    popoverDescription({ title: "Details", rows: [textRow("name", "Alice"), textRow("role", "Admin")], side: "top" }),
  ).toEqual({
    title: "Details",
    side: "top",
    align: "start",
    width: 320,
    rows: [
      { id: "name", kind: "text", label: "Alice" },
      { id: "role", kind: "text", label: "Admin" },
    ],
  });
});

test("native action resolution preserves keep-open and rejects disabled ancestors", () => {
  const child = { id: "child", kind: "action" as const, label: "Child" };
  const model = popoverDescription({
    rows: [
      { id: "parent", kind: "submenu", label: "Parent", disabled: true, children: [child] },
      { id: "hold", kind: "action", label: "Hold", keepOpen: true },
      { id: "control", kind: "toggle", label: "Toggle", checked: true },
    ],
  });
  expect(popupAction(model, "child")).toBeUndefined();
  expect(popupAction(model, "hold")?.keepOpen).toBe(true);
  expect(popupAction(model, "control")).toBeUndefined();
  expect(popupAction(model, "missing")).toBeUndefined();
});
