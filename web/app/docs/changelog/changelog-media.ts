/**
 * Supplementary media and narrative for changelog versions.
 *
 * CHANGELOG.md remains the source of truth for the raw list of changes.
 * This file adds titles, feature highlights, and narrative descriptions
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
  /** Big title shown as a heading, summarizing the main features. */
  title: string;
  /** Hero image shown at the top of the version entry. */
  hero?: string;
  /** Feature highlights shown inline below the title. */
  features?: FeatureHighlight[];
}

export const changelogMedia: Record<string, VersionMedia> = {
  "0.61.0": {
    title: "Tab Colors, Command Palette, Pin Workspaces",
    features: [
      {
        title: "Tab Colors",
        description:
          "Right-click any workspace in the sidebar to assign it a color. There are 17 presets to choose from, or pick a custom color. Colors show on the tab itself and on the workspace indicator rail.",
        image: "/changelog/0.61.0-tab-colors.png",
      },
      {
        title: "Command Palette",
        description:
          "Hit Cmd+Shift+P to open a searchable command palette. Every action in cmux is here: creating workspaces, toggling the sidebar, checking for updates, switching windows. Keyboard shortcuts are shown inline so you can learn them as you go.",
        image: "/changelog/0.61.0-command-palette.png",
      },
      {
        title: "Open With",
        description:
          "You can now open your current directory in VS Code, Cursor, Zed, Xcode, Finder, or any other editor directly from the command palette. Type \"open\" and pick your editor.",
        image: "/changelog/0.61.0-open-with.png",
      },
      {
        title: "Pin Workspaces",
        description:
          "Pin a workspace to keep it at the top of the sidebar. Pinned workspaces stay put when other workspaces reorder from notifications or activity.",
        image: "/changelog/0.61.0-pin-workspace.png",
      },
      {
        title: "Workspace Metadata",
        description:
          "The sidebar now shows richer context for each workspace: PR links that open in the browser, listening ports, git branches, and working directories across all panes.",
        image: "/changelog/0.61.0-workspace-metadata.png",
      },
    ],
  },
  "0.60.0": {
    title: "Tab Context Menu, DevTools, Notification Rings, CJK Input",
    features: [
      {
        title: "Tab Context Menu",
        description:
          "Right-click any tab in a pane to rename it, close tabs to the left or right, move it to another pane, or create a new terminal or browser tab next to it. You can also zoom a pane to full size and mark tabs as unread.",
        image: "/changelog/0.60.0-tab-context-menu.png",
      },
      {
        title: "Browser DevTools",
        description:
          "The embedded browser now has full WebKit DevTools. Open them with the standard shortcut and they persist across tab switches. Inspect elements, debug JavaScript, and monitor network requests without leaving cmux.",
        image: "/changelog/0.60.0-devtools.png",
      },
      {
        title: "Notification Rings",
        description:
          "When a background process sends a notification (like a long build finishing), the terminal pane shows an animated ring so you can spot it at a glance without switching workspaces.",
      },
      {
        title: "CJK Input",
        description:
          "Full IME support for Korean, Chinese, and Japanese. Preedit text renders inline with proper anchoring and sizing, so composing characters works the way you'd expect.",
        image: "/changelog/0.60.0-cjk-input.png",
      },
      {
        title: "Claude Code",
        description:
          "Claude Code integration is now enabled by default. Each workspace gets its own routing context, and agents can read terminal screen contents via the API.",
      },
    ],
  },
  "0.32.0": {
    title: "Sidebar Metadata",
    features: [
      {
        title: "Sidebar Metadata",
        description:
          "The sidebar now displays git branch, listening ports, log entries, progress bars, and status pills for each workspace.",
      },
    ],
  },
};
