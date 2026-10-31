// l10n-allow-file: gallery-only sample labels, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { ChatMenuItem } from "./ChatHeaderTools";
import { ThreadTitle } from "./ThreadTitle";

const menuRows = (move: "local" | "cloud", targets: readonly string[]): ChatMenuItem[] => [
  { key: "rename", label: "Rename", icon: "action.edit", shortcutLabel: "R", onSelect: () => undefined },
  { key: "fork", label: "Fork", icon: "agent.fork", shortcutLabel: "F", onSelect: () => undefined },
  {
    key: "move",
    label: move === "local" ? "Move to machine" : "Bring Back Local",
    icon: "machine.remote",
    children:
      move === "local"
        ? targets.map((label) => ({ key: label, label, onSelect: () => undefined }))
        : [{ key: move, label: "Bring Back Local", onSelect: () => undefined }],
  },
  {
    key: "open",
    label: "Open in",
    icon: "app.open.external",
    children: [
      { key: "browser", label: "Browser", onSelect: () => undefined },
      { key: "terminal", label: "Terminal", onSelect: () => undefined },
      { key: "window", label: "New window", onSelect: () => undefined },
    ],
  },
  { key: "archive", label: "Archive", icon: "inbox", shortcutLabel: "A", onSelect: () => undefined },
  { key: "delete", label: "Delete", icon: "action.delete", shortcutLabel: "D", onSelect: () => undefined },
];

function TitleMenuGallery({
  title,
  move,
  targets,
  treatment,
}: {
  title: string;
  move: "local" | "cloud";
  targets: readonly string[];
  treatment: string;
}) {
  return (
    <div className={`acpmux-shell acpmux-thread-title-gallery acpmux-thread-title-gallery--${treatment}`}>
      <header className="acpmux-header">
        <div className="acpmux-header-status-slot">
          <ThreadTitle title={title} menu={() => menuRows(move, targets)} />
        </div>
        <div className="acpmux-header-tools" />
      </header>
      <main className="acpmux-thread-title-gallery-copy">
        <p>Click the title to rename, fork, move or open this chat.</p>
        <p className="acpmux-muted">
          Move uses the chat’s existing Cloud transfer path; Delete purges the session and closes the tab.
        </p>
      </main>
    </div>
  );
}

const open: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-thread-title-trigger" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="menu"]'));
};

export default componentEntry<{
  title: string;
  move: "local" | "cloud";
  targets: readonly string[];
  treatment: string;
}>({
  id: "agent-pane.thread-title",
  title: "Chat title menu",
  area: "Agent pane",
  pane: true,
  height: 240,
  widths: { narrow: 360, normal: 520, wide: 760 },
  anchors: [{ selector: ".acpmux-thread-title-gallery" }],
  covers: [
    "agent-session/acpmux/header/ThreadTitle.tsx#ThreadTitle",
    "agent-session/acpmux/header/ChatHeaderTools.tsx#ChatMenu",
  ],
  styles: () => Promise.all([import("../styles.css"), import("./header.css"), import("./ThreadTitle.gallery.css")]),
  load: async () => TitleMenuGallery,
  variants: {
    "local-plain": {
      props: {
        title: "Phone to computer connection",
        move: "local",
        targets: ["Build Mac", "Review Mac"],
        treatment: "plain",
      },
      play: open,
      note: "Local chat: the submenu lists eligible Cloud machines from the host, and Delete purges then closes the tab.",
    },
    "remote-glass": {
      props: { title: "Review remote agent output", move: "cloud", targets: [], treatment: "glass" },
      play: open,
      note: "Cloud chat: Bring Back Local uses the same existing transfer path as the environment picker.",
    },
    "compact-long": {
      props: {
        title: "Investigate the flaky reconnect path across the build fleet",
        move: "local",
        targets: ["Build Mac"],
        treatment: "compact",
      },
      play: open,
      note: "Narrow header treatment: a long title ellipsizes while the chevron and action menu remain reachable.",
    },
  },
});
