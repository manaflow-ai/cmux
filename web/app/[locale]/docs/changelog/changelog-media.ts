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
  "0.64.4": {
    title: "SSH Files Polish, Vault Pi & Hermes, Browser Cookie Import",
    features: [
      {
        title: "SSH Files Polish",
        description:
          "The Files sidebar now follows SSH workspaces and shows the remote root instead of the local macOS path. SSH workspace descriptors restore on relaunch, and new guarded cmux://ssh deep links prompt before launching ssh so unfamiliar links can't run arbitrary commands.",
      },
      {
        title: "Vault Pi and Hermes",
        description:
          "Pi sessions now restore across relaunch via Vault, and Hermes Agent hooks pipe into the sidebar like Claude, Codex, OpenCode, Gemini, and Rovo Dev. Per-agent toggles let you hide individual agent session restores from Vault.",
      },
      {
        title: "Browser Cookie Import",
        description:
          "A new cmux browser cookies import CLI brings cookies from other browsers into cmux's browser panes so logged-in sessions follow you over.",
      },
      {
        title: "Quality-of-life Polish",
        description:
          "Welcome sidebar toggle shortcuts, Insert Path and Insert Relative Path in the file explorer right-click menu, a warnBeforeClosingTab toggle to opt back into the close confirmation prompt, plus fixes for IME, command palette Escape, modified Backspace in the omnibar, and stale terminal colors after theme switches.",
      },
    ],
  },
  "0.64.0": {
    title: "Session Restore on Quit, Passkeys, File Explorer, Task Manager",
    features: [
      {
        title: "Session Restore on Quit",
        description:
          "Closing the last window with the red X no longer drops your work. cmux restores prior panes on relaunch and resumes Claude Code, Codex, OpenCode, Gemini, and Rovo Dev sessions where you left off.",
      },
      {
        title: "Passkeys, WebAuthn, and FIDO2",
        description:
          "Sign in to passkey-protected sites directly inside cmux browser panes. Reworked inside-out signing keeps the notarized Developer ID build compatible with macOS authentication services.",
      },
      {
        title: "File Explorer",
        description:
          "A Finder-like file explorer sidebar with full SSH support so remote workspaces get the same tree view as local ones.",
      },
      {
        title: "Task Manager",
        description:
          "A built-in Task Manager window plus cmux top CLI shows a live snapshot of windows, workspaces, panes, surfaces, and browser webviews, with jumps from the manager into the matching surface.",
      },
    ],
  },
  "0.63.0": {
    title: "SSH, Claude Code Teams, oh-my-openagent, Browser Import, Minimal Mode",
    features: [
      {
        title: "SSH",
        description:
          "cmux ssh user@remote creates a workspace for a remote machine. Browser panes route through the remote network so localhost just works. Drag an image into a remote session to upload via scp. Coding agent notifications come home to your local sidebar. Reconnects on drops.",
      },
      {
        title: "Claude Code Teams",
        description:
          "cmux claude-teams launches Claude Code's experimental teammate mode with one command. It sets up the environment, fakes a tmux session, and translates tmux commands into native cmux splits. Teammates stack vertically in a right column with sidebar metadata and notifications.",
      },
      {
        title: "oh-my-openagent",
        description:
          "cmux omo integrates oh-my-openagent (formerly oh-my-opencode), which orchestrates specialist agents across Claude, GPT, and Gemini in parallel. Same tmux shim as claude-teams, auto-installs the plugin, notifications route through cmux.",
      },
      {
        title: "Browser Profile Import",
        description:
          "Import cookies, history, and sessions from Chrome, Arc, Brave, Firefox, Safari, and 20+ browsers. The import wizard detects installed browsers, lets you pick profiles, and injects everything into cmux's browser panes so you're already logged in.",
      },
      {
        title: "Minimal Mode",
        description:
          "Hide the titlebar for a distraction-free terminal. Controls move to the sidebar and appear on hover. Toggle from the command palette or Settings.",
      },
      {
        title: "Custom Commands",
        description:
          "Define project-specific actions in cmux.json that launch from the command palette. One file per repo, no global config needed.",
      },
    ],
  },
  "0.62.0": {
    title: "Markdown Viewer, Browser Find, Vi Copy Mode, and Localization",
    features: [
      {
        title: "Markdown Viewer",
        description:
          "Open Markdown files in their own panel and keep them live with file watching. Notes, READMEs, and docs refresh automatically as the file changes on disk.",
      },
      {
        title: "Find in Browser",
        description:
          "Browser panels now support Cmd+F with inline find controls, so you can search long docs, dashboards, and issue threads without leaving cmux.",
      },
      {
        title: "Vi Copy Mode",
        description:
          "Terminal scrollback now has a keyboard copy mode with vi-style navigation, making it much easier to inspect and copy from large output buffers.",
      },
      {
        title: "Custom Notification Sounds",
        description:
          "Choose from bundled sounds or pick your own audio file so background task notifications are easier to notice and easier to personalize.",
      },
      {
        title: "Expanded Localization",
        description:
          "cmux now includes Japanese plus 16 additional languages, and a per-app language override lets you change the UI language without changing macOS system settings.",
      },
    ],
  },
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
