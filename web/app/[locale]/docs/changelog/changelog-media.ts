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
  /** Translation key for this feature (used to look up localized title/description). */
  key: string;
  title: string;
  description: string;
  /** Path relative to /public, e.g. "/changelog/0.61.0-command-palette.png" */
  image?: string;
}

export interface VersionMedia {
  /** Whether this version should render a spotlight heading above its highlights. */
  showTitle?: boolean;
  /** Hero image shown at the top of the version entry. */
  hero?: string;
  /** Feature highlights shown inline below the title. */
  features?: FeatureHighlight[];
}

export const changelogMedia: Record<string, VersionMedia> = {
  "0.62.0": {
    showTitle: true,
    features: [
      {
        key: "markdownViewer",
        title: "Markdown Viewer",
        description:
          "Open Markdown files in their own panel and keep them live with file watching. Notes, READMEs, and docs refresh automatically as the file changes on disk.",
      },
      {
        key: "findInBrowser",
        title: "Find in Browser",
        description:
          "Browser panels now support Cmd+F with inline find controls, so you can search long docs, dashboards, and issue threads without leaving cmux.",
      },
      {
        key: "viCopyMode",
        title: "Vi Copy Mode",
        description:
          "Terminal scrollback now has a keyboard copy mode with vi-style navigation, making it much easier to inspect and copy from large output buffers.",
      },
      {
        key: "customNotificationSounds",
        title: "Custom Notification Sounds",
        description:
          "Choose from bundled sounds or pick your own audio file so background task notifications are easier to notice and easier to personalize.",
      },
      {
        key: "expandedLocalization",
        title: "Expanded Localization",
        description:
          "cmux now includes Japanese plus 16 additional languages, and a per-app language override lets you change the UI language without changing macOS system settings.",
      },
    ],
  },
  "0.61.0": {
    showTitle: true,
    features: [
      {
        key: "tabColors",
        title: "Tab Colors",
        description:
          "Right-click any workspace in the sidebar to assign it a color. There are 17 presets to choose from, or pick a custom color. Colors show on the tab itself and on the workspace indicator rail.",
        image: "/changelog/0.61.0-tab-colors.png",
      },
      {
        key: "commandPalette",
        title: "Command Palette",
        description:
          "Hit Cmd+Shift+P to open a searchable command palette. Every action in cmux is here: creating workspaces, toggling the sidebar, checking for updates, switching windows. Keyboard shortcuts are shown inline so you can learn them as you go.",
        image: "/changelog/0.61.0-command-palette.png",
      },
      {
        key: "openWith",
        title: "Open With",
        description:
          "You can now open your current directory in VS Code, Cursor, Zed, Xcode, Finder, or any other editor directly from the command palette. Type \"open\" and pick your editor.",
        image: "/changelog/0.61.0-open-with.png",
      },
      {
        key: "pinWorkspaces",
        title: "Pin Workspaces",
        description:
          "Pin a workspace to keep it at the top of the sidebar. Pinned workspaces stay put when other workspaces reorder from notifications or activity.",
        image: "/changelog/0.61.0-pin-workspace.png",
      },
      {
        key: "workspaceMetadata",
        title: "Workspace Metadata",
        description:
          "The sidebar now shows richer context for each workspace: PR links that open in the browser, listening ports, git branches, and working directories across all panes.",
        image: "/changelog/0.61.0-workspace-metadata.png",
      },
    ],
  },
  "0.60.0": {
    showTitle: true,
    features: [
      {
        key: "tabContextMenu",
        title: "Tab Context Menu",
        description:
          "Right-click any tab in a pane to rename it, close tabs to the left or right, move it to another pane, or create a new terminal or browser tab next to it. You can also zoom a pane to full size and mark tabs as unread.",
        image: "/changelog/0.60.0-tab-context-menu.png",
      },
      {
        key: "browserDevTools",
        title: "Browser DevTools",
        description:
          "The embedded browser now has full WebKit DevTools. Open them with the standard shortcut and they persist across tab switches. Inspect elements, debug JavaScript, and monitor network requests without leaving cmux.",
        image: "/changelog/0.60.0-devtools.png",
      },
      {
        key: "notificationRings",
        title: "Notification Rings",
        description:
          "When a background process sends a notification (like a long build finishing), the terminal pane shows an animated ring so you can spot it at a glance without switching workspaces.",
      },
      {
        key: "cjkInput",
        title: "CJK Input",
        description:
          "Full IME support for Korean, Chinese, and Japanese. Preedit text renders inline with proper anchoring and sizing, so composing characters works the way you'd expect.",
        image: "/changelog/0.60.0-cjk-input.png",
      },
      {
        key: "claudeCode",
        title: "Claude Code",
        description:
          "Claude Code integration is now enabled by default. Each workspace gets its own routing context, and agents can read terminal screen contents via the API.",
      },
    ],
  },
  "0.32.0": {
    showTitle: true,
    features: [
      {
        key: "sidebarMetadata",
        title: "Sidebar Metadata",
        description:
          "The sidebar now displays git branch, listening ports, log entries, progress bars, and status pills for each workspace.",
      },
    ],
  },
};
