// l10n-allow-file: gallery fixtures (public-safe release notes), not shipped UI.
// A day whose highlight carries a before/after pair as the signed notes do (release-notes.py
// add_gallery_media: [after, before], each with its role), next to one with a lone picture and a
// plain change. The pictures are the repo's What's New layout before and after (design/), inlined
// as the host inlines verified media.
import after from "../../gallery/fixtures/whats-new/compare-whats-new-after.png?inline";
import before from "../../gallery/fixtures/whats-new/compare-whats-new-before.png?inline";
import archive from "../../gallery/fixtures/whats-new/clip-sidebar-archive.webp?inline";
import type { ReleaseNotes } from "./types";

export const compareNotes: ReleaseNotes[] = [
  {
    build: "4015000000001",
    shortVersion: "1.0.0-nightly.4015000000001",
    date: "2026-11-08",
    highlights: [
      {
        id: "whats-new-wide",
        category: "improved",
        title: "What's New uses the whole pane",
        body: "Descriptions use the pane's width and each change's picture sits beside it, instead of one narrow centered column.",
        media: [
          {
            url: after,
            kind: "image",
            alt: "What's New after: wide rows with the version in the margin.",
            role: "after",
          },
          { url: before, kind: "image", alt: "What's New before: one narrow centered card.", role: "before" },
        ],
      },
      {
        id: "sidebar-archive",
        category: "new",
        title: "Archive sidebar workspaces, groups and links",
        body: "Right-click a workspace and choose Archive: it moves to the end of its group, dimmed, until you Unarchive it.",
        media: [{ url: archive, kind: "image", alt: "A workspace archived to the end of its group." }],
      },
    ],
    changes: ["Sidebar: the Updated card keeps its place while dragged"],
    items: [{ title: "Sidebar: the Updated card keeps its place while dragged" }],
  },
];
