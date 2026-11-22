// l10n-allow-file: gallery fixtures (sample chat title and actions), not shipped UI.
// The glass toolbar taste prototype (glassToolbar.experiment.ts): today's row beside the three arms
// (keycaps, groups, labels), each in a roomy pane and a narrow one, inside the App's `.acpmux-header`
// so the fold (headerOverflow.ts) and header.css's container rules run as in the pane.
import { createElement } from "react";
import type { ComponentProps, CSSProperties } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { ShortcutLabels } from "../shortcuts";
import type { ChatMenuItem } from "./chatHeaderToolsModel";
import type { GlassToolbarLook } from "./glassToolbar.experiment";
import { PanelToggle } from "./PanelToggle";
import { FORK_ICON } from "../icons/forkIcon";

type ToolsProps = ComponentProps<typeof import("./ChatHeaderTools").ChatHeaderTools>;
type Props = ToolsProps & {
  /// Gallery-only: the pane's width in px, so one stage shows the roomy and the narrow header.
  paneWidth: number;
  /// Gallery-only: the chat title on the header's left, as the App draws it outside the tab row.
  title: string;
};

const ROOMY = 900;
const NARROW = 420;
/// A pane narrow enough that the fold (headerOverflow.ts) moves trailing buttons into "...".
const TIGHT = 320;
/// A wide pane, a full window's chat.
const WIDE = 1280;

/// The keycaps the host pushes (AgentPaneShortcuts.swift) for the header's actions, as a person with
/// the default bindings has them; ⌘K is the agent pane's Search Chats.
const SHORTCUTS: ShortcutLabels = {
  splitRight: "⌘D",
  splitDown: "⇧⌘D",
  splitBrowserRight: "⌥⌘X",
  openDiffViewer: "⇧⌘G",
  renameTab: "⇧⌘R",
  closeTab: "⌘W",
  "agentPane.searchChats": "⌘K",
};

const noop = () => undefined;
const menu = (): ChatMenuItem[] => [
  { key: "rename", label: "Rename", icon: "action.edit", shortcutAction: "renameTab", onSelect: noop },
  { key: "pin", label: "Pin", icon: "action.pin", shortcutAction: "palette.toggleTabPin", onSelect: noop },
  "separator",
  { key: "sideChat", label: "New side chat", icon: "agent.chat.new", onSelect: noop },
  { key: "fork", label: "Fork", icon: FORK_ICON, onSelect: noop },
  "separator",
  { key: "new-window", label: "Open in new window", icon: "app.open.external", onSelect: noop },
  "separator",
  { key: "archive", label: "Archive", icon: "inbox", onSelect: noop },
  { key: "close", label: "Close", icon: "tab.close", shortcutAction: "closeTab", onSelect: noop },
];

const summary = createElement(PanelToggle, {
  className: "acpmux-summary-button",
  label: "Session Info",
  shown: false,
  onToggle: noop,
});

// A chat that edited files: Changes and Files beside the panel toggle, then Terminal, Split Down,
// Browser and New tab, the chat menu and the search chip.
const chat = (glass: GlassToolbarLook | "off", paneWidth: number): Props => ({
  paneWidth,
  title: "Fix the login redirect loop",
  glass,
  onSearch: noop,
  tabTools: true,
  onTerminal: noop,
  onSplitDown: noop,
  onBrowser: noop,
  onSideTabs: noop,
  onFiles: noop,
  hasChanges: true,
  onChanges: noop,
  summary,
  menu,
  onMenuOpen: async () => undefined,
});

const glassShown =
  (look: GlassToolbarLook | "off"): Play =>
  async (ctx) => {
    // The App's workspace push (headerState `workspace`): the glass title reads "cmux" over "3 chats".
    if (look !== "off") {
      const { setHeaderState } = await import("./headerState");
      setHeaderState({ workspace: { title: "cmux", chats: 3 } });
    }
    await ctx.waitFor(() =>
      look === "off"
        ? ctx.document.querySelector(".acpmux-header-tools:not([data-glass-toolbar])")
        : ctx.document.querySelector(`.acpmux-header-tools[data-glass-toolbar="${look}"] .acpmux-glass-search`),
    );
  };

const menuOpen: Play = async (ctx) => {
  await glassShown("keycaps")(ctx);
  await ctx.click({ role: "button", name: "Chat actions" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="menu"]'));
};

const NOTES: Record<GlassToolbarLook | "off", string> = {
  off: "Today's row, for comparison: plain 24px squares on a 26px pitch, no search chip.",
  keycaps:
    "Keycaps: round glass singles, the split actions in one glass capsule with a keycap after each glyph, round ..., and the ⌘K search chip last.",
  groups: "Groups: the same glass shapes, glyphs only in the capsule; only the search chip shows its keycap.",
  labels: "Labels: capsule buttons show glyph, name and keycap, as a web nav does; they fold to glyphs when narrow.",
};

const looks = ["off", "keycaps", "groups", "labels"] as const;
const variants = Object.fromEntries(
  looks.flatMap((look) => [
    [look, { note: `${NOTES[look]} A ${ROOMY}px pane.`, props: chat(look, ROOMY), play: glassShown(look) }],
    [
      `${look}-narrow`,
      {
        note: `${NOTES[look]} A ${NARROW}px pane: header.css's container rules drop the labels and keycaps (the search chip's too).`,
        props: chat(look, NARROW),
        play: glassShown(look),
      },
    ],
  ]),
);

export default componentEntry<Props>({
  id: "agent-pane.glass-toolbar",
  title: "Chat header: glass toolbar groups",
  area: "Agent pane",
  experimental: true,
  height: 360,
  widths: { narrow: NARROW, normal: ROOMY, wide: WIDE },
  anchors: [{ selector: ".acpmux-header-tools" }],
  covers: [
    "agent-session/acpmux/header/ChatHeaderTools.tsx#ChatHeaderTools",
    "agent-session/acpmux/header/glassToolbar.experiment.ts#glassToolbarLook",
  ],
  keywords: ["glass", "keycaps", "capsule", "toolbar", "search chip"],
  load: () =>
    Promise.all([
      import("./ChatHeaderTools"),
      import("../shortcuts"),
      import("./ThreadTitle"),
      import("./ChatHeaderStatus"),
    ]).then(
      ([tools, shortcuts, thread, status]) =>
        ({ paneWidth, title, ...props }: Props) =>
          // The App's pane outside the tab row: the stage, its header with the chat's title on the
          // left and the trailing tools group the fold measures.
          createElement(
            "section",
            {
              className: "acpmux-shell",
              style: { width: paneWidth, maxWidth: "100%", height: 320 } as CSSProperties,
            },
            createElement(
              "div",
              {
                className: "acpmux-stage",
                style: { flex: "1 1 0", minWidth: 0, display: "flex", flexDirection: "column" },
              },
              createElement(
                "header",
                { className: "acpmux-header" },
                createElement(
                  status.ChatHeaderStatus,
                  { status: "" },
                  createElement(thread.ThreadTitle, { title, glass: props.glass !== "off" }),
                ),
                createElement(
                  "div",
                  { className: "acpmux-handoff-header-tools" },
                  createElement(
                    shortcuts.ShortcutsContext,
                    { value: SHORTCUTS },
                    createElement(tools.ChatHeaderTools, props),
                  ),
                ),
              ),
            ),
          ),
    ),
  // The pane's stylesheets as the app ships them, and the shared glass tokens the round buttons use.
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../../../ui/popupSurface.css"),
      import("../../../ui/glass/glass.css"),
      import("./header.css"),
    ]),
  checks: {
    popupLayer: { value: true, reason: "The glass chat menu must be the top, unclipped, opaque layer." },
    anchorMovePx: { value: 0, reason: "Opening the chat menu uses a portal and must not move the header tool row." },
  },
  variants: {
    ...variants,
    "keycaps-wide": {
      note: `${NOTES.keycaps} A ${WIDE}px pane: a full window's chat.`,
      props: chat("keycaps", WIDE),
      play: glassShown("keycaps"),
    },
    "keycaps-tight": {
      note: `${NOTES.keycaps} A ${TIGHT}px pane: the fold moves the trailing buttons into the round ... as today's row does.`,
      props: chat("keycaps", TIGHT),
      play: glassShown("keycaps"),
    },
    "keycaps-menu": {
      note: "Keycaps, the chat menu open from the round ...: the glass menu over the chat.",
      height: 520,
      props: chat("keycaps", ROOMY),
      play: menuOpen,
    },
  },
});
