// l10n-allow-file: gallery fixtures (public-safe release notes from release-notes/next/highlights), not shipped UI.
// Release notes in the shape the app serves after cx-urd.61: a What's New document with light and
// dark media (inlined, as the host inlines verified media), and nightlies with only commit subjects.
import groupsDark from "../../gallery/fixtures/whats-new/workspace-groups-dark.jpg?inline";
import groupsLight from "../../gallery/fixtures/whats-new/workspace-groups-light.jpg?inline";
import type { ReleaseNotes, WhatsNewEntry } from "./types";

const entry = (
  id: string,
  category: WhatsNewEntry["category"],
  title: string,
  summary: string,
  extra: Partial<WhatsNewEntry> = {},
): WhatsNewEntry => ({
  id,
  category,
  title: { en: title, ja: title },
  summary: { en: summary },
  ...extra,
});

export const journalNotes: ReleaseNotes[] = [
  {
    build: "3720357960413",
    shortVersion: "1.0.0-nightly.413",
    date: "2026-10-11",
    highlights: [],
    changes: [
      "cmux-next sidebar: a long group or list shows its first rows then Show N more (#23671)",
      "cmux-next sidebar: rows draw no status words; needs you is one yellow dot, never Done (#23767)",
      "cmux-next sidebar: a working row shows no running time (#23812)",
    ],
    items: [
      { title: "cmux-next sidebar: a long group or list shows its first rows then Show N more", pr: 23671 },
      { title: "cmux-next sidebar: rows draw no status words; needs you is one yellow dot, never Done", pr: 23767 },
      { title: "cmux-next sidebar: a working row shows no running time", pr: 23812 },
    ],
    whatsNew: {
      version: "1.0.0-nightly.413",
      channel: "nightly",
      date: "2026-10-11",
      headline: { en: "Workspace groups you can see at a glance" },
      entries: [
        entry(
          "workspace-groups",
          "new",
          "Workspace groups you can see at a glance",
          "Each group now has a colored label, and its workspaces sit on one band of its color. Give a group an icon, and pin it so it stays when its last workspace closes.",
          {
            media: {
              kind: "image",
              light: groupsLight,
              dark: groupsDark,
              alt: { en: "The sidebar with three workspace groups" },
            },
            tryIt: { action: "space.new" },
            docs: "https://cmux.com/docs/sidebar",
          },
        ),
        entry(
          "undo-tab-close",
          "new",
          "Undo a tab close from a toast",
          "One click or ⌘Z brings back the tabs you closed, in their places.",
        ),
        entry(
          "agents-browser",
          "new",
          "Agents can use the cmux browser and computer use",
          "Sessions that cmux starts get both tools; computer use still runs only when you ask.",
        ),
        entry(
          "restart-instant",
          "improved",
          "Restart to Update reacts at once",
          "Terminals and agents keep running across the restart.",
          {
            tryIt: { action: "palette.checkForUpdates" },
          },
        ),
        entry(
          "group-band-color",
          "improved",
          "Group labels keep their band color",
          "A group's label stays the color of its band when you rename it, collapse it or move it to another window, so the sidebar reads the same everywhere.",
          {
            media: {
              kind: "image",
              light: groupsLight,
              dark: groupsDark,
              alt: { en: "Workspace groups, each label in its band's color" },
            },
          },
        ),
        entry(
          "fast-tabs",
          "improved",
          "Faster browser tab switches",
          "The tab you leave stays in place, hidden, and shows again at once.",
        ),
        entry(
          "app-store-window",
          "fixed",
          "The App Store always opens in your window",
          "It never opens a window of its own.",
          { tryIt: { action: "appStore.show" } },
        ),
        entry("settings-every-window", "fixed", "Settings opens with your values in every window", ""),
        entry(
          "terminal-env",
          "security",
          "Terminal secrets no longer stay on disk",
          "A reopened tab no longer restores its environment from disk.",
        ),
      ],
    },
  },
  {
    build: "3720357960412",
    shortVersion: "1.0.0-nightly.412",
    date: "2026-10-10",
    highlights: [
      {
        id: "all-chats",
        title: "Every chat on your Mac, in one place",
        body: "cmux now finds the chats of Claude Code, Codex, OpenCode, Pi, Gemini CLI, Cursor agent and Amp on this Mac. Search them in the command palette and open one: it resumes in its own harness. Nothing leaves the Mac.",
        action: { id: "palette.newAgentChat", title: "Open a Chat" },
      },
    ],
    summary: [
      { group: "changed", title: "cmux tells you what changed after every update" },
      { group: "fixed", title: "A machine that cannot connect stays in the sidebar" },
    ],
    changes: [
      "cmux NEXT Home: no stale divider line through the Chief chat after the list clamps (#23998)",
      "updates: switch channels in place, both ways (Dev ↔ Nightly) (#23845)",
    ],
    items: [
      { title: "cmux NEXT Home: no stale divider line through the Chief chat after the list clamps", pr: 23998 },
      { title: "updates: switch channels in place, both ways (Dev ↔ Nightly)", pr: 23845 },
    ],
  },
  {
    build: "3720357960411",
    shortVersion: "1.0.0-nightly.411",
    date: "2026-10-09",
    highlights: [],
    changes: [
      "cmux NEXT browser: files dragged in from Finder drop into the Chromium page (#23790)",
      "cmux NEXT sidebar: remote Priority rows age out and keep their read marks (#23609)",
      "cmux-next: rapid Cmd-W on terminal tabs closes one tab per press (#23646)",
    ],
    items: [
      { title: "cmux NEXT browser: files dragged in from Finder drop into the Chromium page", pr: 23790 },
      { title: "cmux NEXT sidebar: remote Priority rows age out and keep their read marks", pr: 23609 },
      { title: "cmux-next: rapid Cmd-W on terminal tabs closes one tab per press", pr: 23646 },
    ],
  },
  {
    build: "3720357960410",
    shortVersion: "1.0.0-nightly.410",
    date: "2026-10-08",
    highlights: [
      {
        id: "terminal-elsewhere",
        title: "A terminal from another machine in any pane",
        body: "A pane can hold a terminal that runs on another connected machine, next to your local tabs. It keeps running on its machine when no tab shows it.",
      },
    ],
    changes: ["cmux NEXT: a restored terminal pane comes back without a key press (#23145)"],
    items: [{ title: "cmux NEXT: a restored terminal pane comes back without a key press", pr: 23145 }],
  },
];

/** One day of nightlies as published on 2026-11-01: each build's digest is made from its summary
    lines, so every build names its entries summary-0, summary-1, … (Leo 2026-11-01 saw rows twice
    on What's New: the page keyed its rows by those ids). One title was cut inside its parentheses
    by an older pipeline. Newest first. */
const digestBuild = (build: string, lines: [WhatsNewEntry["category"], string, string][]): ReleaseNotes => ({
  build,
  shortVersion: `1.0.0-nightly.${build}`,
  date: "2026-11-01",
  highlights: [],
  changes: [],
  whatsNew: {
    version: `1.0.0-nightly.${build}`,
    channel: "nightly",
    date: "2026-11-01",
    headline: { en: lines[0]![1] },
    entries: lines.map(([category, title, summary], index) => entry(`summary-${index}`, category, title, summary)),
  },
});

export const dayOfNightlies: ReleaseNotes[] = [
  digestBuild("4134492295001", [
    ["new", "Show the Feed in Chief draws in Settings > Chief > Look", ""],
    ["improved", "Ultracode and Fast mode do not block Bring Back Local", ""],
    ["improved", "Drop saved incognito task ids whose tasks ended", "While the app was stopped."],
    ["improved", "Routing follow-ups (trim recovered route", "Prepared presets only, cap before split)."],
    ["fixed", "A title or preview cut with an ellipsis never ends inside an emoji", ""],
  ]),
  digestBuild("4134335440201", [
    ["improved", "Cloud start replaces rejected Claude logins", "Cloud start replaces rejected Claude logins."],
    ["improved", "A message's More menu opens upward when it does not fit below", ""],
  ]),
  digestBuild("4133822529301", [
    ["improved", "Replace a Claude login the provider rejects", ""],
    ["improved", "A pinned harness still takes a model", "A queued subagent keeps its model after a restart."],
  ]),
  digestBuild("4132569907101", [
    ["improved", "Each machine's projects carry its own colored computer", "Not one globe."],
    ["improved", "An attached video's speech goes to the agent", "Transcribed on this Mac."],
  ]),
  digestBuild("4132418488301", [
    ["improved", "Copy again on the machine's new link after updating it", ""],
    ["fixed", "A key right after an arrow key sees the caret the arrow moved", ""],
  ]),
  digestBuild("4131908227901", [
    ["improved", "A look at a video's frames draws as a filmstrip card", ""],
    ["improved", "Inbox rows share the tool rows' icon column", "A sender's mark is its real harness."],
  ]),
];
