// l10n-allow-file: gallery fixtures (sample keybindings), not shipped UI.
import { keybindingsPageEntry } from "../../gallery/format";
import type { Binding } from "./types";

const bindings: Binding[] = [
  {
    id: 0,
    key: "cmd+shift+p",
    display: "⌘⇧P",
    command: "palette.open",
    title: "Open Command Palette",
    when: null,
    source: "default",
    conflicts: [1],
  },
  {
    id: 1,
    key: "cmd+shift+p",
    display: "⌘⇧P",
    command: "history.open",
    title: "Show History",
    when: "surface.kind == 'browser'",
    source: "user",
    conflicts: [0],
  },
  {
    id: 2,
    key: "cmd+p",
    display: "⌘P",
    command: "palette.files",
    title: "Go to File",
    when: null,
    source: "default",
    conflicts: [],
  },
  {
    id: 3,
    key: "cmd+k cmd+s",
    display: "⌘K ⌘S",
    command: "keybindings.open",
    title: "Open Keyboard Shortcuts",
    when: null,
    source: "default",
    conflicts: [],
  },
  {
    id: 4,
    key: "cmd+w",
    display: "⌘W",
    command: "tab.close",
    title: "Close Tab",
    when: null,
    source: "ghostty",
    conflicts: [],
  },
  {
    id: 5,
    key: "cmd+shift+d",
    display: "⌘⇧D",
    command: "split.down",
    title: "Split Down",
    when: null,
    source: "default",
    conflicts: [],
    removed: true,
  },
  {
    id: 6,
    key: "ctrl+tab",
    display: "⌃Tab",
    command: "tab.next",
    title: "Next Tab",
    when: null,
    source: "ghostty-fallback",
    conflicts: [],
  },
  {
    id: 7,
    key: "cmd+alt+n",
    display: "⌘⌥N",
    command: "workspace.new",
    title: "New Workspace",
    when: "!dialog.open",
    source: "app",
    conflicts: [],
  },
];

const many = Array.from({ length: 42 }, (_, index): Binding => ({
  id: index + 20,
  key: index % 3 === 0 ? "cmd+k cmd+d" : `cmd+alt+${(index % 9) + 1}`,
  display: index % 3 === 0 ? "⌘K ⌘D" : `⌘⌥${(index % 9) + 1}`,
  command: `workspace.feature${index + 1}.open`,
  title: `Open workspace feature ${index + 1}: ${"long descriptive command ".repeat(2)}`,
  when: index % 3 === 0 ? "surface.kind == 'terminal'" : null,
  source: index % 4 === 0 ? "user" : "default",
  conflicts: index % 3 === 0 ? [9] : [],
}));

export default keybindingsPageEntry({
  id: "pages.keybindings",
  title: "Keyboard Shortcuts",
  area: "Pages",
  height: 640,
  widths: { narrow: 560, normal: 1000, wide: 1400 },
  covers: ["page:cmux.keybindings", "pages/keybindings/KeybindingsPage.tsx#KeybindingsPage"],
  variants: {
    empty: { note: "No shortcuts match the current table.", bindings: [] },
    loading: { note: "The shortcut owner is still loading its table.", loading: true, bindings },
    normal: { note: "Defaults, user overrides, conflicts, removed rows and Ghostty rows.", bindings },
    "read-only": {
      note: "Ghostty and removed defaults are visible but cannot be edited.",
      bindings: bindings.filter(
        (binding) => binding.source === "ghostty" || binding.source === "ghostty-fallback" || binding.removed,
      ),
    },
    "many-bindings": {
      note: "A long shortcut table with scrolling and long command names.",
      bindings: [...bindings, ...many],
    },
    "selected-editing": {
      note: "A selected row has its context condition editor open.",
      bindings,
      query: { selectIndex: 0, editIndex: 0 },
    },
    recording: {
      note: "The search key recorder is active and waiting for strokes.",
      bindings,
      query: { record: true },
    },
    "conflicts-only": { note: "Only conflicting shortcuts are shown.", bindings, query: { conflictsOnly: true } },
    unsupported: {
      note: "The host reports that shortcut writes are unavailable.",
      bindings,
      error: "unsupported",
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".keys-remove:not(:disabled)"));
        await ctx.click({ selector: ".keys-remove:not(:disabled)" });
        await ctx.waitFor(() => ctx.document.querySelector(".keys-notice"));
      },
    },
    "network-error": { note: "The shortcut owner is disconnected.", bindings, error: "network" },
    "not-found-error": {
      note: "A keymap import/export source is missing.",
      bindings,
      error: "not-found",
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".keys-import:not(:disabled)"));
        await ctx.click({ selector: ".keys-import:not(:disabled)" });
        await ctx.waitFor(() => ctx.document.querySelector(".keys-notice"));
      },
    },
  },
});
