// l10n-allow-file: gallery fixtures (public-safe release notes from release-notes/next/highlights), not shipped UI.
// An update span whose highlights carry their clips as the signed notes do (release-notes.py: the
// `clip:` line, alt = the clip spec's caption), with the clips scripts/cmux-next/media/whats-new-clips.py
// recorded on the fleet. Inlined, as the host inlines verified media.
import digits from "../../gallery/fixtures/whats-new/clip-command-digits-select-tabs.webp?inline";
import composer from "../../gallery/fixtures/whats-new/clip-persistent-goals-composer.webp?inline";
import archive from "../../gallery/fixtures/whats-new/clip-sidebar-archive.webp?inline";
import links from "../../gallery/fixtures/whats-new/clip-terminal-cmd-click-links.webp?inline";
import type { Highlight, ReleaseNotes } from "./types";

const clip = (url: string, alt: string) => [{ url, kind: "image", alt }];

const highlights: Highlight[] = [
  {
    id: "sidebar-archive",
    category: "new",
    title: "Archive sidebar workspaces, groups and links",
    body: "Right-click a workspace (under More), a group (under Options) or a link and choose Archive: it moves to the end of its group, dimmed. Unarchive puts it back where it was.",
    media: clip(
      archive,
      "Right-click a workspace and choose Archive: it moves to the end of its group, dimmed, until you Unarchive it.",
    ),
    action: { id: "workspace.toggleArchive", title: "Archive/Unarchive Workspace" },
  },
  {
    id: "persistent-goals-composer",
    category: "improved",
    title: "Goals and composer controls stay within reach",
    body: "Codex goals stay visible when you reopen a chat, and messages can steer a goal already in progress. New Tab keeps its look switch beside the composer and exposes access and available speed controls before your first message.",
    media: clip(
      composer,
      "New Tab keeps its look dots beside the composer, and the access mode and model are there before your first message.",
    ),
    action: { id: "palette.newAgentChat", title: "New Agent Chat" },
  },
  {
    id: "command-digits-select-tabs",
    category: "improved",
    title: "⌘1…9 can switch tabs instead of workspaces",
    body: "Set Command-1 to 9 Select to Tabs in Settings > Keyboard, and ⌘1…9 pick the focused pane's tabs while ⌃1…9 pick workspaces. Workspaces stays the default.",
    media: clip(digits, "Set Command-1 to 9 Select to Tabs, and ⌘1…9 jump straight to the focused pane's tabs."),
  },
  {
    id: "terminal-cmd-click-links",
    category: "fixed",
    title: "Command-click opens terminal links every time",
    body: "Hold Command over a link in any terminal to underline it, and click to open it. Links a program wrapped onto two rows open whole, and file:line opens at that line.",
    media: clip(
      links,
      "Hold Command over a link or file:line in a terminal to underline it, then click to open it in a tab.",
    ),
  },
  {
    id: "smooth-chat-starts-and-switches",
    category: "fixed",
    title: "Chat starts and switches stay smooth",
    body: "Starting a chat keeps the New Tab visible until its folder is ready, and switching to a busy chat no longer exposes a blank transcript before its messages arrive.",
  },
];

export const clipNotes: ReleaseNotes[] = [
  {
    build: "4011902817001",
    shortVersion: "1.0.0-nightly.4011902817001",
    date: "2026-10-24",
    highlights,
    changes: ["cmux-next sidebar: Archive/Unarchive for workspaces, groups and links"],
    items: [{ title: "cmux-next sidebar: Archive/Unarchive for workspaces, groups and links" }],
  },
  {
    build: "4009633177301",
    shortVersion: "1.0.0-nightly.4009633177301",
    date: "2026-10-24",
    highlights: [],
    changes: ["fix(cmux-next updater): no Waiting to Relaunch card; a held idle install is the staged update"],
    items: [{ title: "fix(cmux-next updater): no Waiting to Relaunch card; a held idle install is the staged update" }],
  },
];

/** The update from the build before these two to the newest. */
export const clipRoute = "from=1.0.0-nightly.4007654379801&to=1.0.0-nightly.4011902817001";
