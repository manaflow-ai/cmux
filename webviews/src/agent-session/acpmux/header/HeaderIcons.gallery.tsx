// l10n-allow-file: gallery fixtures (sample chat actions), not shipped UI.
// The top-right thunderdome's contextual direction (headerRelevance.ts): today's row beside the two
// contextual styles, in the moments that decide which icons are relevant.
import { createElement } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { NeedsYouButton } from "../needsYou/NeedsYou";
import type { ChatMenuItem } from "./ChatHeaderTools";
import type { HeaderIconsStyle } from "./headerRelevance";
import { PanelToggle } from "./PanelToggle";

type Props = {
  onTerminal: (mode: "toggle" | "open") => void;
  onBrowser: (mode: "toggle" | "open") => void;
  hasChanges?: boolean;
  onChanges?: (mode: "toggle" | "open") => void;
  previewUrl?: string;
  onPreview?: (url: string | undefined, mode: "toggle" | "open") => void;
  summary: ReturnType<typeof createElement>;
  inbox?: ReturnType<typeof createElement>;
  inboxRelevant?: boolean;
  menu: () => ChatMenuItem[];
};

const noop = () => undefined;
const menu = (): ChatMenuItem[] => [
  { key: "rename", label: "Rename", icon: "action.edit", onSelect: noop },
  "separator",
  { key: "close", label: "Close", icon: "tab.close", onSelect: noop },
];
const summary = createElement(PanelToggle, {
  className: "acpmux-summary-button",
  label: "Chat summary",
  shown: false,
  icon: "view.list",
  onToggle: noop,
});
const inbox = createElement(NeedsYouButton, {
  items: [],
  actions: { answer: async () => undefined, goTo: noop, ask: async () => undefined },
});

// A new chat: nothing edited, no page, nothing open beside it, no asks.
const newChat: Props = {
  onTerminal: noop,
  onBrowser: noop,
  onChanges: noop,
  onPreview: noop,
  summary,
  inbox,
  inboxRelevant: false,
  menu,
};
// The chat edited files in its last turn.
const edited: Props = { ...newChat, hasChanges: true };
// The chat edited files and started a local page.
const withPage: Props = { ...edited, previewUrl: "http://localhost:5173/" };

const style =
  (headerIcons: HeaderIconsStyle, lit: string[] = [], then?: Play): Play =>
  async (ctx) => {
    const { setHeaderState } = await import("./headerState");
    setHeaderState({ headerIcons, lit });
    await ctx.waitFor(() =>
      headerIcons === "standard"
        ? ctx.document.querySelector(".acpmux-header-tools:not([data-header-icons])")
        : ctx.document.querySelector(`.acpmux-header-tools[data-header-icons="${headerIcons}"]`),
    );
    await then?.(ctx);
  };

const shown = (ctx: Parameters<Play>[0]) =>
  [...ctx.document.querySelectorAll(".acpmux-header-tools > .acpmux-header-tool-group-actions [data-quick-action]")].map(
    (button) => button.getAttribute("data-quick-action"),
  );
const expectShown =
  (...ids: string[]): Play =>
  async (ctx) => {
    const got = shown(ctx);
    if (JSON.stringify(got) !== JSON.stringify(ids)) throw new Error(`expected ${ids.join(",")}, drew ${got.join(",")}`);
  };

// Peek at rest: the dormant icons hold their room, invisible; hovered: they fade in, nothing else moves.
const peekHover: Play = async (ctx) => {
  const panel = ctx.find({ role: "button", name: "Chat summary" });
  const before = panel.getBoundingClientRect().left;
  await ctx.hover({ role: "button", name: "Chat summary" });
  const dormant = ctx.find({ selector: "[data-header-dormant]" });
  await ctx.waitFor(() => ctx.document.defaultView!.getComputedStyle(dormant).opacity === "1");
  if (panel.getBoundingClientRect().left !== before) throw new Error("a resting icon moved when the dormant ones showed");
};

export default componentEntry<Props>({
  id: "agent-pane.header-icons-contextual",
  title: "Chat header icons: contextual",
  area: "Agent pane",
  height: 160,
  widths: { normal: 560 },
  anchors: [{ selector: ".acpmux-header-tools" }],
  covers: [
    "agent-session/acpmux/header/ChatHeaderTools.tsx#ChatHeaderTools",
    "agent-session/acpmux/header/headerRelevance.ts#headerRelevance",
  ],
  load: () => import("./ChatHeaderTools").then((module) => (props: Props) => createElement(module.ChatHeaderTools, props)),
  styles: () => Promise.all([import("../styles.css"), import("../../../ui/popupSurface.css"), import("./header.css")]),
  variants: {
    "standard-new-chat": {
      note: "Today (standard): a new chat already shows the panel toggle, Needs You, Terminal, Browser and the menu.",
      props: newChat,
      play: style("standard", [], expectShown("terminal", "browser")),
    },
    "standard-with-page": {
      note: "Today (standard) after an edit and a local page: Changes joins; the globe looks the same as before.",
      props: withPage,
      play: style("standard", [], expectShown("changes", "terminal", "browser")),
    },
    "contextual-new-chat": {
      note: "Contextual: a new chat is the panel toggle and the menu. Terminal, Browser and Needs You wait in the menu.",
      props: newChat,
      play: style("contextual", [], expectShown()),
    },
    "contextual-edited": {
      note: "Contextual after the chat edits files: Changes appears, alone.",
      props: edited,
      play: style("contextual", [], expectShown("changes")),
    },
    "contextual-with-page": {
      note: "Contextual once the chat starts a local page: the globe appears, and opens that page.",
      props: withPage,
      play: style("contextual", [], expectShown("changes", "browser")),
    },
    "contextual-terminal-open": {
      note: "Contextual with the chat's terminal open (from the menu or its shortcut): Terminal shows lit, so it can close it.",
      props: edited,
      play: style("contextual", ["splitRight"], expectShown("changes", "terminal")),
    },
    "contextual-asks": {
      note: "Contextual with an open ask: Needs You shows with its count.",
      props: { ...newChat, inboxRelevant: true },
      play: style("contextual", [], async (ctx) => void ctx.find({ selector: ".acpmux-needs-you-button" })),
    },
    "peek-rest": {
      note: "Contextual, the rest on hover, at rest: the same calm row as Contextual.",
      props: edited,
      play: style("contextualPeek", [], expectShown("changes")),
    },
    "peek-hover": {
      note: "Contextual, the rest on hover, hovered: Needs You, Terminal and Browser fade in at the row's leading end; nothing at rest moves.",
      props: edited,
      play: style("contextualPeek", [], peekHover),
    },
  },
});
