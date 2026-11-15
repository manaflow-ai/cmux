// l10n-allow-file: gallery fixture data, not shipped UI.
// Fixture projects for the project-caps gallery: cmux is long (37 chats) with the selected chat, one pinned chat,
// one waiting on you (yellow), two unread (blue) and one running mid-list; ghostty fits under the
// cap; hq has one unread and one waiting chat; cmux-tui is long enough for its own "Show more".
import type { CapChat, CapProject, ChatState } from "./projectCapsModel";

const harnesses = ["claude", "codex", "opencode", "pi"];

const cmuxTitles = [
  "Sidebar: cap each project at five",
  "Fix the flaky terminal restore test",
  "Why does the dock flicker on resize?",
  "Port the palette ranker to Rust",
  "Composer: paste images from Finder",
  "Bench chat switch on the god fixture",
  "Cloud workspaces: reconnect banner",
  "Spinner period back to 1400 ms",
  "Drag a group onto another window",
  "Unread dot at 8 pt everywhere",
  "Hover card names the machine once",
  "Keybindings page conflicts filter",
  "Trailing column for close and search",
  "Session tree folds persist",
  "Diff viewer: word-level highlights",
  "Release notes for the nightly",
  "Settings: Agents harness health",
  "Markdown page table of contents",
  "Icon picker skin tone memory",
  "Titlebar plus on the window line",
  "History page cookie backups",
  "Done fold counts a subtree once",
  "Passwords page import flow",
  "Changelog page links to PRs",
  "Editor page read-only reasons",
  "Apps at the bottom of the sidebar",
  "Glass veil on sidebar cards",
  "Remote host second line",
  "Minimal mode text on lead",
  "Fork lineage is not nesting",
  "Pinned section boundary",
  "Workspace colour picks",
  "Lift card stands on the window",
  "Needs-you mark in a 14 pt box",
  "Red failure glyph size",
  "Search field on the trail column",
  "Agent pane session info panel",
];

const ages = [
  "now",
  "2m",
  "6m",
  "14m",
  "31m",
  "1h",
  "2h",
  "3h",
  "5h",
  "8h",
  "19h",
  "1d",
  "2d",
  "3d",
  "4d",
  "5d",
  "6d",
  "1w",
];

function chats(
  prefix: string,
  titles: readonly string[],
  marks: Record<number, { state?: ChatState; pinned?: boolean; selected?: boolean }>,
): CapChat[] {
  return titles.map((title, index) => ({
    id: `${prefix}-${index}`,
    title,
    harness: harnesses[(index * 7 + prefix.length) % harnesses.length]!,
    age: ages[Math.min(ages.length - 1, Math.floor((index * ages.length) / titles.length))]!,
    state: marks[index]?.state ?? "idle",
    ...(marks[index]?.pinned ? { pinned: true } : {}),
    ...(marks[index]?.selected ? { selected: true } : {}),
  }));
}

export const capProjects: readonly CapProject[] = [
  {
    id: "cmux",
    name: "cmux",
    chats: chats("cmux", cmuxTitles, {
      0: { selected: true },
      2: { state: "running" },
      4: { state: "unread" },
      9: { pinned: true },
      12: { state: "waiting" },
      21: { state: "unread" },
    }),
  },
  {
    id: "ghostty",
    name: "ghostty",
    chats: chats("ghostty", ["Bump ghostty and rerun the bench", "Kitty graphics in tmux", "Font fallback for CJK"], {
      0: { state: "running" },
    }),
  },
  {
    id: "hq",
    name: "hq",
    chats: chats(
      "hq",
      [
        "Draft the release notes",
        "Fleet registry routes",
        "Rulebook word cap",
        "Weekly digest",
        "Nightly promote checklist",
        "Machine roles table",
        "Compendium: lazy blob fetch",
        "Handbook: before you ship",
      ],
      { 1: { state: "unread" }, 5: { state: "waiting" } },
    ),
  },
  {
    id: "cmux-tui",
    name: "cmux-tui",
    chats: chats(
      "tui",
      Array.from(
        { length: 14 },
        (_, index) =>
          [
            "Port the tab strip",
            "Mouse reporting in panes",
            "Scrollback search",
            "Theme sync with NEXT",
            "Status line segments",
            "Keymap import",
            "Split resize keys",
            "Session restore",
            "Clipboard over ssh",
            "Truecolor detection",
            "Bell to unread dot",
            "Pane zoom",
            "Copy mode",
            "Command palette",
          ][index]!,
      ),
      {},
    ),
  },
];
