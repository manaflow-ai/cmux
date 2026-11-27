// l10n-allow-file: gallery fixtures (sample keybindings), not shipped UI.
import { keybindingsPageEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
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
  {
    id: 8,
    key: "",
    display: "",
    command: "sidebar.toggle",
    title: "Toggle Sidebar",
    when: null,
    source: "user",
    conflicts: [],
    unset: true,
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

const readOnlyBindings = bindings.filter(
  (binding) => binding.source === "ghostty" || binding.source === "ghostty-fallback" || binding.removed,
);

const searchKeyboard: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".keys-row"));
  await ctx.focus({ selector: ".keys-search" });
  await ctx.type("open");
  await ctx.waitFor(() => (ctx.find({ selector: ".keys-search" }) as HTMLInputElement).value === "open");

  // Escape clears the query while keeping the search field as the keyboard surface.
  await ctx.press("Escape");
  await ctx.waitFor(() => {
    const search = ctx.find({ selector: ".keys-search" }) as HTMLInputElement;
    return search.value === "" && ctx.document.activeElement === search;
  });

  const selectedTitle = () =>
    ctx.document.querySelector<HTMLElement>(".keys-row.selected .keys-command-title")?.textContent;
  await ctx.press("ArrowDown");
  await ctx.waitFor(() => selectedTitle() === "Close Tab");
  await ctx.press("ArrowDown");
  await ctx.waitFor(() => selectedTitle() === "Go to File");
  await ctx.press("ArrowUp");
  await ctx.waitFor(() => selectedTitle() === "Close Tab");
  // Move back to an editable row so Return exercises the row recording path.
  await ctx.press("ArrowDown");
  await ctx.waitFor(() => selectedTitle() === "Go to File");
  await ctx.press("Enter");
  await ctx.waitFor(() => {
    const search = ctx.find({ selector: ".keys-search" }) as HTMLInputElement;
    const row = ctx.document.querySelector<HTMLElement>(".keys-row.recording");
    return (
      row?.querySelector(".keys-command-title")?.textContent === "Go to File" && ctx.document.activeElement === search
    );
  });
};

const clickKeys: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".keys-key-button"));
  await ctx.click({ selector: ".keys-key-button" });
  await ctx.waitFor(() => ctx.document.querySelector(".keys-row.recording .keys-key-button[aria-pressed='true']"));
  await ctx.waitFor(() => ctx.document.querySelector(".keys-recorder"));
};

const searchReadOnly: Play = async (ctx) => {
  const search = { selector: ".keys-search" } as const;
  await ctx.waitFor(() => ctx.document.querySelector(".keys-row"));
  await ctx.focus(search);
  await ctx.press("ArrowDown");
  await ctx.waitFor(
    () =>
      ctx.document.querySelector<HTMLElement>(".keys-row.selected .keys-command-title")?.textContent === "Close Tab",
  );
  await ctx.press("Enter");
  await ctx.waitFor(() => {
    const field = ctx.find(search) as HTMLInputElement;
    const row = ctx.document.querySelector<HTMLElement>(".keys-row.selected");
    return ctx.document.activeElement === field && row !== null && !row.classList.contains("recording");
  });
};

const searchComposition: Play = async (ctx) => {
  const search = { selector: ".keys-search" } as const;
  await ctx.waitFor(() => ctx.document.querySelector(".keys-row"));
  await ctx.focus(search);
  const selectedTitle = () =>
    ctx.document.querySelector<HTMLElement>(".keys-row.selected .keys-command-title")?.textContent;
  await ctx.press("ArrowDown");
  await ctx.press("ArrowDown");
  await ctx.waitFor(() => selectedTitle() === "Go to File");

  const dispatch = (key: string, isComposing: boolean, keyCode?: number) => {
    const KeyboardEventConstructor = ctx.document.defaultView?.KeyboardEvent;
    if (!KeyboardEventConstructor) throw new Error("gallery document has no KeyboardEvent constructor");
    const event = new KeyboardEventConstructor("keydown", {
      bubbles: true,
      cancelable: true,
      isComposing,
      key,
    });
    if (keyCode !== undefined) Object.defineProperty(event, "keyCode", { configurable: true, value: keyCode });
    (ctx.find(search) as HTMLInputElement).dispatchEvent(event);
    return event;
  };

  // IME candidate navigation must not move the selected row or cancel composition.
  const composingArrow = dispatch("ArrowDown", true);
  await ctx.waitFor(() => selectedTitle() === "Go to File" && !composingArrow.defaultPrevented);
  // Older WebKit reports only the legacy 229 keyCode on the commit key.
  const composingEnter = dispatch("Enter", false, 229);
  await ctx.waitFor(
    () =>
      selectedTitle() === "Go to File" &&
      !composingEnter.defaultPrevented &&
      !ctx.document.querySelector(".keys-row.recording"),
  );
};

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
    normal: {
      note: "Defaults, user overrides, conflicts, removed rows, a row with no keys and Ghostty rows.",
      bindings,
    },
    "click-keys": {
      note: "A click on a row's keys opens the recorder popover over them.",
      bindings,
      play: clickKeys,
    },
    "read-only": {
      note: "Ghostty and removed defaults are visible but cannot be edited.",
      bindings: readOnlyBindings,
    },
    "search-keyboard": {
      note: "Search Escape clears the query, arrows move selection, and Return records an editable row.",
      bindings,
      checks: {
        layoutShiftMax: {
          value: 0.35,
          reason: "Filtering changes the visible row set; the fixed scroll region keeps the page controls stable.",
        },
      },
      play: searchKeyboard,
    },
    "search-readonly": {
      note: "Return does not start recording when search selection lands on a Ghostty or removed row.",
      bindings: readOnlyBindings,
      play: searchReadOnly,
    },
    "search-composition": {
      note: "IME candidate navigation and commit stay in composition instead of moving or recording a row.",
      bindings,
      play: searchComposition,
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
