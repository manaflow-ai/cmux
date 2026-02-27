/**
 * Supplementary media and narrative for changelog versions.
 *
 * CHANGELOG.md remains the source of truth for the raw list of changes.
 * This file adds hero images, feature highlights, and narrative summaries
 * for major releases. Versions not listed here render as plain bullet lists.
 *
 * Images live in public/changelog/ and should be 2x (e.g. 1600×900 for a
 * 800px display width). Use PNG for UI screenshots, WebP for photos.
 */

export interface FeatureHighlight {
  title: string;
  description: string;
  /** Path relative to /public, e.g. "/changelog/0.61.0-command-palette.png" */
  image?: string;
}

export interface VersionMedia {
  /** One-line narrative summary shown below the version heading. */
  summary: string;
  /** Hero image shown at the top of the version entry. */
  hero?: string;
  /** Feature highlights with optional screenshots. Shown as a grid above the bullet list. */
  features?: FeatureHighlight[];
}

export const changelogMedia: Record<string, VersionMedia> = {
  "0.61.0": {
    summary:
      "Open with your favorite editor, command palette, tab colors, workspace metadata, and a refreshed theme across the entire app.",
    features: [
      {
        title: "Open With",
        description:
          "Open your current directory in VS Code, Cursor, Zed, Xcode, Finder, or any other editor directly from the command palette.",
        image: "/changelog/0.61.0-open-with.png",
      },
      {
        title: "Tab Colors",
        description:
          "Right-click any workspace to assign a color. 17 presets plus a custom color picker for visual organization.",
        image: "/changelog/0.61.0-tab-colors.png",
      },
      {
        title: "Command Palette",
        description:
          "Cmd+Shift+P opens a searchable palette for actions, settings, and switching between windows and workspaces.",
      },
      {
        title: "Workspace Metadata",
        description:
          "Sidebar shows PR links, listening ports, git branches, and working directories across all panes in a workspace.",
        image: "/changelog/0.61.0-workspace-metadata.png",
      },
    ],
  },
  "0.60.0": {
    summary:
      "Tab context menus, browser file uploads, notification rings, CJK input, and Claude Code integration.",
    // hero: "/changelog/0.60.0-hero.png",
    features: [
      {
        title: "Tab Context Menu",
        description:
          "Right-click any tab to rename, close, mark as unread, or move it to another workspace.",
        // image: "/changelog/0.60.0-tab-context-menu.png",
      },
      {
        title: "Notification Rings",
        description:
          "Terminal panes show an animated ring when a background process sends a notification.",
        // image: "/changelog/0.60.0-notification-rings.png",
      },
      {
        title: "CJK Input",
        description:
          "Full IME support for Korean, Chinese, and Japanese input methods.",
        // image: "/changelog/0.60.0-cjk-input.png",
      },
      {
        title: "Claude Code Integration",
        description:
          "Claude Code is enabled by default with workspace-aware routing and read-screen APIs.",
        // image: "/changelog/0.60.0-claude-code.png",
      },
    ],
  },
  "0.32.0": {
    summary: "Sidebar metadata, port scanning, and browser workspace targeting.",
    features: [
      {
        title: "Sidebar Metadata",
        description:
          "Git branch, listening ports, log entries, progress bars, and status pills in the sidebar.",
        // image: "/changelog/0.32.0-sidebar-metadata.png",
      },
    ],
  },
};
