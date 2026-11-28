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
      "sidebar: group labels keep their band color",
      "groups: pin keeps an empty group",
      "toast: undo closed tabs",
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
    changes: ["chats: discovery across homes", "updates: Updated card every channel"],
  },
  {
    build: "3720357960411",
    shortVersion: "1.0.0-nightly.411",
    date: "2026-10-09",
    highlights: [],
    changes: [
      "browser: popups belong to their session",
      "remote: datalist popups past the page edge",
      "labels keep their text width",
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
    changes: ["remote: terminal tab on a machine"],
  },
];
