// l10n-allow-file: gallery fixtures (sample chat actions), not shipped UI.
// The top-right thunderdome's variant D (headerTrio.ts): today's row beside the three controls ("...",
// the panel toggle and New), New's menu with its preview, New after a terminal, and the narrowest pane.
import { createElement } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { ChatMenuItem } from "./chatHeaderToolsModel";
import type { HeaderControls, NewKind } from "./headerTrio";
import { PanelToggle } from "./PanelToggle";

type Props = {
  onTerminal: (mode: "toggle" | "open") => void;
  onBrowser: (mode: "toggle" | "open") => void;
  hasChanges?: boolean;
  onChanges?: (mode: "toggle" | "open") => void;
  summary: ReturnType<typeof createElement>;
  menu: () => ChatMenuItem[];
  newButton: { available: Partial<Record<NewKind, boolean>>; make: (kind: NewKind) => void };
};

const noop = () => undefined;
// The chat menu of Leo's proposal (2026-11-07): rename, pin, new side chat, fork, share, copy, open in a
// new window, archive.
const menu = (): ChatMenuItem[] => [
  { key: "rename", label: "Rename", icon: "action.edit", shortcutAction: "renameTab", onSelect: noop },
  { key: "pin", label: "Pin", icon: "action.pin", shortcutAction: "palette.toggleTabPin", onSelect: noop },
  "separator",
  { key: "sideChat", label: "New side chat", icon: "agent.chat.new", onSelect: noop },
  { key: "fork", label: "Fork", icon: "agent.fork", onSelect: noop },
  "separator",
  { key: "share", label: "Share", icon: "app.open.external", onSelect: noop },
  { key: "copy", label: "Copy", icon: "action.copy", onSelect: noop },
  "separator",
  {
    key: "newWindow",
    label: "Open in new window",
    icon: "workspace.new",
    shortcutAction: "tab.moveToNewWindow",
    onSelect: noop,
  },
  "separator",
  { key: "archive", label: "Archive", icon: "inbox", onSelect: noop },
];
const summary = createElement(PanelToggle, {
  className: "acpmux-summary-button",
  label: "Session Info",
  shown: false,
  onToggle: noop,
});

// A chat that edited files: today's row shows Changes, Terminal and Browser beside the panel toggle.
const chat: Props = {
  onTerminal: noop,
  onBrowser: noop,
  hasChanges: true,
  onChanges: noop,
  summary,
  menu,
  newButton: { available: {}, make: noop },
};

const layout =
  (headerControls: HeaderControls, then?: Play): Play =>
  async (ctx) => {
    const { setHeaderState } = await import("./headerState");
    setHeaderState({ headerControls });
    await ctx.waitFor(() =>
      headerControls === "trio"
        ? ctx.document.querySelector('.acpmux-header-tools[data-header-controls="trio"]')
        : ctx.document.querySelector(".acpmux-header-tools:not([data-header-controls])"),
    );
    await then?.(ctx);
  };

// Exactly three controls, on one line: "...", the panel toggle, New (its face and chevron are one control).
const threeOnOneLine: Play = async (ctx) => {
  const tools = ctx.find({ selector: '.acpmux-header-tools[data-header-controls="trio"]' });
  const controls = [
    tools.querySelector(".acpmux-header-more"),
    tools.querySelector(".acpmux-summary-button"),
    tools.querySelector(".acpmux-header-new"),
  ];
  if (controls.some((control) => !control)) throw new Error("a control is missing");
  if (tools.querySelectorAll("[data-quick-action]").length > 0) throw new Error("a quick action button is still drawn");
  const tops = new Set(controls.map((control) => Math.round(control!.getBoundingClientRect().top)));
  if (tops.size !== 1) throw new Error("the three controls wrapped");
  const right = tools.getBoundingClientRect().right;
  if (right > ctx.document.documentElement.clientWidth) throw new Error("the controls run past the pane");
};

const openNew: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "New…" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-header-new-preview"));
};

export default componentEntry<Props>({
  id: "agent-pane.header-controls-trio",
  title: "Chat header: three controls (thunderdome D)",
  area: "Agent pane",
  height: 360,
  widths: { narrow: 200, normal: 560 },
  anchors: [{ selector: ".acpmux-header-tools" }],
  covers: [
    "agent-session/acpmux/header/ChatHeaderTools.tsx#ChatHeaderTools",
    "agent-session/acpmux/header/HeaderNewButton.tsx#HeaderNewButton",
  ],
  load: () =>
    import("./ChatHeaderTools").then((module) => (props: Props) => createElement(module.ChatHeaderTools, props)),
  styles: () => Promise.all([import("../styles.css"), import("../../../ui/popupSurface.css"), import("./header.css")]),
  variants: {
    standard: {
      note: "Today (standard): the panel toggle, Changes, Terminal, Browser and the chat menu.",
      props: chat,
      play: layout("standard"),
    },
    trio: {
      note: "Three controls: the chat menu, the panel toggle, and New. Changes waits in the chat menu with its shortcut.",
      props: chat,
      play: layout("trio", threeOnOneLine),
    },
    "trio-menu": {
      note: "Three controls, the chat menu open: rename, pin, new side chat, fork, share, copy, open in new window, archive, then the quick actions the row no longer draws.",
      props: chat,
      play: layout("trio", async (ctx) => {
        await ctx.click({ role: "button", name: "Chat actions" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-chat-menu-popover"));
      }),
    },
    "trio-new-menu": {
      note: "New's chevron: every kind, and a preview of where the one under the pointer opens. Before any pick, the face opens the New Tab page.",
      props: chat,
      play: layout("trio", openNew),
    },
    "trio-new-preview-terminal": {
      note: "New's menu with the pointer on New terminal: the preview draws the terminal right of the chat, with its key.",
      props: chat,
      play: layout("trio", async (ctx) => {
        await openNew(ctx);
        await ctx.hover({ selector: '.acpmux-header-new-popover [data-value="terminal"]' });
        await ctx.waitFor(() => ctx.document.querySelector('[data-new-preview="terminal"]'));
      }),
    },
    "trio-after-terminal": {
      note: "After a terminal from New's menu, the face makes a terminal again: one click for whoever makes terminals.",
      props: chat,
      play: layout("trio", async (ctx) => {
        await openNew(ctx);
        await ctx.click({ selector: '.acpmux-header-new-popover [data-value="terminal"]' });
        await ctx.waitFor(() => ctx.document.querySelector('[data-header-new="terminal"]'));
      }),
    },
  },
});
