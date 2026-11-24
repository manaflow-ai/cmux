// l10n-allow-file: gallery fixtures for the command palette's Return outcome looks.
// Beyer's P3 ("show the outcome before the action", 6f3c76146074 put a Return keycap on New Tab's highlighted
// row) pushed further on the + palette: the highlighted row says what Return will do, with the verb and,
// where it matters, the target. Plus the P4 placeholder that names what the field searches, and descriptions
// that only restate their title left out. Every look is a PaletteMenu prop; `together` is PaletteMenu's default (Leo, 2026-11-22),
// and the other variants pin the looks before it (the sidebar's "Search", every description drawn).
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { PaletteMenu } from "./PaletteMenu";
import type { PaletteReturnLook, PaletteSection } from "./paletteMenuModel";
import { Icon } from "./icons/Icon";

const open: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-picker-button" });
};

// The highlight moves to an open tab: the verb and the outcome line follow it.
const toTab: Play = async (ctx) => {
  await open(ctx);
  await ctx.press("ArrowDown");
  await ctx.press("ArrowDown");
};

const icon = (name: Parameters<typeof Icon>[0]["name"]) => <Icon name={name} size={16} />;

const SECTIONS: PaletteSection[] = [
  {
    title: "Chats",
    verb: "Open",
    choices: [
      {
        id: "chat.login",
        name: "Fix the login bug",
        description: "Claude Code, 4 min ago",
        icon: icon("agent.chat"),
        outcome: "opens “Fix the login bug” in this pane",
      },
      {
        id: "chat.keycaps",
        name: "Palette keycaps",
        description: "Codex, 1 h ago",
        icon: icon("agent.chat"),
        outcome: "opens “Palette keycaps” in this pane",
      },
    ],
  },
  {
    title: "Open Tabs",
    verb: "Switch to",
    choices: [
      {
        id: "tab.pr",
        name: "manaflow-ai/cmux #49798",
        description: "github.com",
        icon: icon("browser"),
        outcome: "switches to the “manaflow-ai/cmux #49798” tab",
      },
    ],
  },
  {
    title: "Tools",
    verb: "Open",
    choices: [
      {
        id: "openBrowser",
        name: "New Browser Tab",
        description: "Open a browser tab",
        icon: icon("browser"),
        outcome: "opens a browser tab beside this chat",
      },
      {
        id: "tab.search",
        name: "Search Tabs",
        description: "Find an open tab",
        icon: icon("tunable.panes"),
        outcome: "lists every open tab to search",
      },
    ],
  },
  {
    title: "Apps",
    verb: "Run",
    choices: [
      {
        id: "app.command.run",
        name: "Run App Command",
        description: "Choose an app command",
        icon: icon("apps.stack"),
        verb: "Choose",
        outcome: "lists the app commands you can run",
      },
    ],
  },
  {
    title: "Chief",
    choices: [
      {
        id: "chief.ask",
        name: "Ask Chief About This…",
        description: "With this chat as context",
        icon: icon("agent.chief"),
        verb: "Ask Chief",
        outcome: "asks the Chief about “Fix the login bug”",
      },
    ],
  },
];

type Props = { look: PaletteReturnLook; placeholder?: string; quiet?: boolean };

function Fixture({ look, placeholder, quiet }: Props) {
  return (
    <div
      style={{
        height: "100%",
        boxSizing: "border-box",
        padding: 24,
        display: "flex",
        justifyContent: "center",
        alignItems: "flex-end",
      }}
    >
      <PaletteMenu
        label="Add"
        button={<span aria-hidden>+</span>}
        sections={SECTIONS}
        returnLook={look}
        placeholder={placeholder ?? BEFORE_PLACEHOLDER}
        quietDescriptions={quiet ?? false}
      />
    </div>
  );
}

const PLACEHOLDER = "Search actions, chats and tabs";
/** The placeholder before: the sidebar's shared search string. */
const BEFORE_PLACEHOLDER = "Search";

export default componentEntry<Props>({
  id: "agent-pane.palette-return-outcome",
  title: "Command palette: what Return does, before Return",
  area: "Agent pane",
  pane: true,
  height: 560,
  widths: { narrow: 360, normal: 520, wide: 760 },
  anchors: [{ selector: ".acpmux-picker-button" }],
  checks: {
    anchorMovePx: { value: 0, reason: "The menu is portaled from a stable + trigger." },
    layoutShiftMax: { value: 0, reason: "The Return cap takes no room from other rows; opening shifts nothing." },
  },
  covers: ["agent-session/acpmux/PaletteMenu.tsx#PaletteMenu"],
  styles: () => Promise.all([import("./styles.css"), import("./keys.css")]),
  load: async () => Fixture,
  variants: {
    now: {
      note: "Before: no sign of what Return does; the shared sidebar placeholder; every description drawn.",
      props: { look: "none" },
      play: open,
    },
    keycap: {
      note: "(a) The highlighted row ends in the Return keycap, as New Tab's rows and the cards draw it.",
      props: { look: "keycap" },
      play: open,
    },
    verb: {
      note: "(b) The keycap with the verb Return carries out: Open, Switch to, Run, Ask Chief.",
      props: { look: "verb" },
      play: open,
    },
    footer: {
      note: "(c) Keycap and verb on the row, and the whole outcome with its target in a quiet line under the list.",
      props: { look: "footer" },
      play: open,
    },
    "footer-tab": {
      note: "(c) after two Downs: the verb and the outcome line follow the highlight to an open tab.",
      props: { look: "footer" },
      play: toTab,
    },
    placeholder: {
      note: "P4: the field names what it searches, not the sidebar's shared string.",
      props: { look: "none", placeholder: PLACEHOLDER },
      play: open,
    },
    quiet: {
      note: "A description that only restates its title goes (New Browser Tab: Open a browser tab; Search Tabs: Find an open tab).",
      props: { look: "none", quiet: true },
      play: open,
    },
    together: {
      note: "The default: (b) keycap and verb, the P4 placeholder, and restating descriptions left out.",
      props: { look: "verb", placeholder: PLACEHOLDER, quiet: true },
      play: open,
    },
  },
});
