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
  "0.64.16": {
    title:
      "AI Auto-Naming, Per-Workspace Env Vars, Left/Right Option as Alt",
    features: [
      {
        title: "AI Auto-Naming for Workspaces and Tabs",
        description:
          "Opt in to have cmux name your workspaces and tabs from the agent conversation running inside them, so a wall of sessions stays readable at a glance.",
      },
      {
        title: "Per-Workspace Environment Variables",
        description:
          "Set environment variables on a workspace and every shell it spawns inherits them, so per-project configuration no longer has to live in your shell profile.",
      },
      {
        title: "Left and Right Option as Alt",
        description:
          "macos-option-as-alt now distinguishes the left and right Option keys, sending sided modifier bits to the terminal. One of our most-requested terminal fixes.",
      },
      {
        title: "iOS Beta Polish",
        description:
          "A redesigned workspace list with groups, unread dots, and last-activity previews; smoother terminal scrolling; cross-device notification dismiss-sync with an authoritative unread badge; and a TestFlight push-notification fix.",
      },
    ],
  },
  "0.64.15": {
    title:
      "Diff Viewer Review Comments, Rebindable ⌘1-9 + Shortcut When-Clauses, In-Process Custom Sidebars, iOS Terminal Composer",
    features: [
      {
        title: "Review Comments in the Diff Viewer",
        description:
          "Comment on changed lines in the diff viewer, persisted per repo. Attach the comment set to a terminal TextBox to hand structured review feedback straight to an agent.",
      },
      {
        title: "Rebindable Shortcuts with When-Clauses",
        description:
          "The Select Workspace and Surface 1…9 shortcuts (⌘1-9) can finally be rebound, and every shortcut supports VS Code-style `when` context clauses so a binding only applies where you want it.",
      },
      {
        title: "Custom Sidebars, In-Process by Default",
        description:
          "Custom sidebars now render in-process by default with a dedicated Settings section, instant toggling, live-resize repaint, and example sidebars to start from.",
      },
      {
        title: "iOS Beta: Composer, Toolbar, Multi-Mac",
        description:
          "An iMessage-style terminal composer with per-terminal drafts, a customizable terminal toolbar, a multi-Mac host switcher, clipboard image paste, and notification forwarding only while you're away from the Mac.",
      },
      {
        title: "Stability Under Load",
        description:
          "Fixes for the macOS 26 launch hang, a macOS 27 beta launch crash, SSH typing lag, sidebar livelocks with many workspaces, white-on-white light themes, and a UI freeze when closing tabs.",
      },
    ],
  },
  "0.64.14": {
    title:
      "iPhone Companion App (Beta), Cross-Window Workspace Drag, Out-of-Process Custom Sidebars",
    features: [
      {
        title: "iPhone Companion App (Beta)",
        description:
          "Pair an iPhone with your Mac from the new Mobile Connect window and attach to your terminals from your phone, with opt-in forwarding of terminal notifications. The iOS beta ships on TestFlight as cmux BETA.",
      },
      {
        title: "Cross-Window Workspace Drag",
        description:
          "Drag a workspace out of one window's sidebar and drop it into another window's sidebar to move it, including grouped workspaces.",
      },
      {
        title: "Out-of-Process Custom Sidebars",
        description:
          "Custom sidebar extensions now run in their own process with an isolated interpreter, so a broken sidebar can't hang or crash cmux, and the interpreter covers a broader set of SwiftUI primitives.",
      },
      {
        title: "Browser Polish",
        description:
          "The omnibar selects the whole URL on the first focusing click (Chrome parity), browser chrome scales with the tab bar font size, a typing beachball with large histories is fixed, and hidden panes no longer stop actively-playing audio or video.",
      },
      {
        title: "Agent Session Fixes",
        description:
          "Claude resume keeps cmux hooks attached so notifications and status tracking survive resumes, Agent Hibernation works for node-backed Claude sessions, and Codex resume preserves CODEX_HOME and pane order.",
      },
    ],
  },
  "0.64.13": {
    title:
      "Browser Focus Mode, SSH Agent Forwarding, Custom Sidebars (Beta), Major Stability Fixes",
    features: [
      {
        title: "Browser Focus Mode",
        description:
          "Browser panes get a focus mode that strips away the surrounding chrome so a single page can take over the pane while you read or work in it.",
      },
      {
        title: "SSH Agent Forwarding",
        description:
          "`cmux ssh` now forwards your local SSH agent, so remote sessions can use your local keys for git pushes and further hops without copying private keys onto the remote.",
      },
      {
        title: "Vibe-Codable Custom Sidebars (Beta)",
        description:
          "Build your own sidebar with a runtime Swift interpreter, behind the Beta Features flag. Edit the sidebar source, validate it from the CLI, and reload it live without rebuilding the app.",
      },
      {
        title: "Browser Mouse Back & Forward",
        description:
          "The browser now responds to the dedicated back and forward buttons on a mouse, so side-button navigation works the way it does in a normal browser.",
      },
      {
        title: "Major Stability & Performance Fixes",
        description:
          "Fixed a settings-observation leak that grew the app to 4.4 GB over a day, a browser render loop burning ~39% of the main thread on every CoreAnimation commit, a WebKit crash after sleep/wake, a 100% CPU hang in the Markdown and file-preview editor, and child processes launching under Rosetta on Apple Silicon.",
      },
    ],
  },
  "0.64.12": {
    title:
      "Diff Viewer Shortcut, Markdown Zoom, Prompt & Remote SSH Fixes",
    features: [
      {
        title: "Diff Viewer Shortcut",
        description:
          "Open the diff viewer with a keyboard shortcut, configurable and editable in Settings alongside every other cmux shortcut.",
      },
      {
        title: "Markdown Viewer Zoom",
        description:
          "The Markdown viewer gains font size and zoom controls, so you can scale rendered docs up or down without leaving the pane.",
      },
      {
        title: "Feed Behind Beta Features",
        description:
          "The Feed is now gated behind Beta Features and off by default, mirroring how the Dock is gated, so it only appears when you opt in.",
      },
      {
        title: "Prompt & Remote SSH Fixes",
        description:
          "Starship and other custom bash prompts no longer go static: the prompt bootstrap composes with your existing PROMPT_COMMAND instead of overwriting it. And `cmux ssh` now reports remote PTY allocation failures loudly instead of failing silently when a plain ssh would have worked.",
      },
      {
        title: "Restored Sidebar Views & Scrollback Colors",
        description:
          "The right-click sidebar view switcher and built-in views (Default Workspaces, Project Worktrees, and others) are back after a 0.64.11 regression. Restored session scrollback no longer keeps a previous theme's colors, fixing white-on-white history after a theme change.",
      },
    ],
  },
  "0.64.11": {
    title:
      "Workspace Groups, Focus & Recently Closed History, Agent Hibernation, Detachable SSH",
    features: [
      {
        title: "Workspace Groups",
        description:
          "Select sidebar workspaces and press ⌘⇧G to gather them under a collapsible header. Each group has an anchor workspace, its own color and icon, and an unread badge on the header. Drag workspaces in and out, reorder inside a group, and control where new workspaces land per group or via cmux.json. A full `cmux workspace-group` CLI namespace creates, colors, moves, focuses, and deletes groups from scripts.",
      },
      {
        title: "Focus & Recently Closed History",
        description:
          "Navigate back and forward through recently focused workspaces and windows straight from the titlebar, with shortcut hints inline. A searchable Recently Closed history pane reopens surfaces you closed, restoring them to their original anchor.",
      },
      {
        title: "Agent Hibernation",
        description:
          "Idle agent sessions hibernate to cut background CPU and memory, then restore on demand with their state intact, so a sidebar full of agents stops competing for resources while you work in one.",
      },
      {
        title: "Detachable SSH PTY Daemon",
        description:
          "Remote SSH sessions now run behind a detachable PTY daemon that keeps the session alive across reconnects, so a dropped network connection no longer kills your remote workspace.",
      },
      {
        title: "Font Size Controls & Notifications Redesign",
        description:
          "The sidebar workspace font size and the workspace tab bar font size (capped at 14pt) are both configurable. The notifications popover was redesigned bigger and more minimal with swipe-to-dismiss, and now uses Hermes hook payloads for richer agent notifications.",
      },
      {
        title: "Fork Conversation, Browser Mute, Diff Viewer",
        description:
          "Fork Conversation moves into the tab right-click menu with configurable destinations, browser tabs gain an audio mute toggle, and `cmux diff` opens a CodeView diff viewer that streams large git diffs before full render.",
      },
    ],
  },
  "0.64.10": {
    title:
      "Copy on Select, Extension Sidebar Prototypes, Browser & Terminal Polish",
    features: [
      {
        title: "Copy on Select",
        description:
          "Highlighting text in the terminal now copies it to the clipboard the instant the mouse is released. The setting is off by default and toggles from Settings so existing selection behavior stays untouched for anyone who relies on it.",
      },
      {
        title: "CmuxExtensionKit Sidebar Prototypes",
        description:
          "An in-tree preview of the upcoming extension API for custom workspace sidebars. Sample sidebars cover an attention queue, browser stack, dev server status, last prompt, and project worktree views, each rendered through the same provider/reducer surface a third-party extension will use.",
      },
      {
        title: "TaskManager 0.64.8 Memory Leak Fix",
        description:
          "The TaskManager panel had a snapshot-boundary violation that retained pane store references inside a lazy list subtree, keeping every entry's `@Published` updates wired to every row. 0.64.10 lifts that state above the list and passes immutable snapshots, so reopening the manager no longer accumulates retained state across sessions.",
      },
      {
        title: "Browser Polish",
        description:
          "The browser loading spinner now runs on Core Animation so it stays smooth during heavy rendering, Cmd+Up and Cmd+Down forward into the browser pane (Google Docs jump-to-top/bottom works), the URL bar no longer steals focus on tab switch, and the markdown viewer renders remote SVG images correctly.",
      },
      {
        title: "Workspace Reorder CLI",
        description:
          "`cmux reorder-workspaces` accepts batch input, supports `--dry-run`, and emits reorder events so scripted layouts can plan a full sidebar reshuffle in one call and react to the changes via the socket.",
      },
      {
        title: "Tab Close Guards",
        description:
          "Tab close buttons can now warn before closing or be hidden entirely from Settings, so a stray click on the X stops dropping the surface without confirmation.",
      },
    ],
  },
  "0.64.9": {
    title: "0.64.8 Memory Leak Hotfix",
    features: [
      {
        title: "Fix 8GB RSS Growth on Non-Git Workspaces",
        description:
          "Git repository search now stops at filesystem root instead of walking forever into `/..`. On older Foundation builds, `deletingLastPathComponent()` could yield `/..` and keep climbing, allocating ever-longer parent paths until the OS OOM killer fired. Non-Git workspaces no longer grow RSS from ~450MB to 8GB within minutes on 0.64.8.",
      },
      {
        title: "Restore Browser Memory Saver Default",
        description:
          "Hidden browser webview renderers discard by default again, reverting the 0.64.8 keep-alive default that exposed the memory regression. The keep-alive behavior remains available as an opt-in setting for workflows that need to preserve DOM state across workspace switches.",
      },
    ],
  },
  "0.64.8": {
    title:
      "Antigravity CLI, Grok Vault Resume, CLI Window Targeting, Browser Screenshots",
    features: [
      {
        title: "Antigravity CLI Integration",
        description:
          "Antigravity joins the supported coding-agent lineup with hook notifications, task manager attribution, and Vault session restore, the same way Claude, Codex, Gemini, and Grok already work in cmux.",
      },
      {
        title: "Native Grok Vault Resume",
        description:
          "Grok sessions can now be resumed natively from Vault. cmux parses registered Grok transcripts by layout, deduplicates sessions across shell-Grok homes, and quotes built-in resume commands so they round-trip cleanly.",
      },
      {
        title: "CLI Window Targeting",
        description:
          "cmux CLI commands now accept `--window` to scope workspace, pane, surface, SSH, VM, notifications, tree, and top flows to a specific window. Refs resolve inside the targeted window, and cross-window pane handles are rejected before they mutate state.",
      },
      {
        title: "Browser Screenshot Clipboard Actions",
        description:
          "Capture a screenshot of the current browser pane and copy it straight to the clipboard, ready to paste into an agent conversation or notes.",
      },
      {
        title: "Browser Webviews Kept Alive",
        description:
          "Reverts the 0.64.7 default of discarding hidden browser webview renderers. Switching back to a hidden browser pane now resumes instantly without reloading. The discard behavior remains available as an opt-in setting.",
      },
      {
        title: "Bug Fixes",
        description:
          "Fixes for minimal-mode pane tabs moving the window when dragged, Option dead-key accent composition (Option+n then a now commits \"ã\"), equalize splits with 3+ panes, Quick Look preview crashes, git index.lock polling, theme override paths leaking from channel builds, sidebar overlay contrast, terminal scheme synchronization on theme reload, restored unread badges, transparent terminal hosting, browser navigation race conditions, and session search ripgrep cancellation crashes.",
      },
    ],
  },
  "0.64.7": {
    title:
      "Grok Build CLI, Browser Memory & Background Preload, Conversation Forks",
    features: [
      {
        title: "Grok Build CLI Integration",
        description:
          "Grok Build joins the supported coding-agent lineup with notifications, task manager attribution, and session restore, the same way Claude, Codex, and Gemini already work in cmux.",
      },
      {
        title: "Browser Memory Reclaim and Background Preload",
        description:
          "Hidden browser webviews can now discard their renderer process to release memory and reappear instantly when you switch back. CLI-created browser panes preload offscreen so the page is ready the moment the workspace becomes visible. Thanks @lidge-jun for the community contributions.",
      },
      {
        title: "Agent Conversation Forks",
        description:
          "New socket commands let you fork an agent conversation off its current turn, so you can branch into a what-if without losing the original thread.",
      },
      {
        title: "Crash Diagnostics from Notifications",
        description:
          "When cmux logs a crash, the notification now opens directly into the crash diagnostics view so you can inspect the breadcrumb trail without digging through state.",
      },
      {
        title: "Bug Fixes",
        description:
          "Fixes for browser deep-link popups (slack://, discord://, zoom://), Cmd-click reload duplicating browser tabs, omnibar arrow key focus races, light-theme foreground rendering with conditional themes, Cmd-hover bounds for spaced file paths, markdown viewer image rendering, surface tab bar action button clipping, task manager attribution, SSH pane sibling kills, background workspace PTY startup, browser IME candidate windows for Japanese / Zhuyin, ripgrep resolution on Nix installs, and Claude sidebar resume config dir overrides.",
      },
    ],
  },
  "0.64.6": {
    title: "SSH Typing Restored, Command Palette Settings Toggles",
    features: [
      {
        title: "SSH Typing Restored",
        description:
          "Fixes a critical regression in 0.64.5 where cmux ssh sessions would connect and render the remote prompt but drop every keystroke. The backgrounded ssh inside the startup wrapper now inherits the wrapper's stdin via <&0, so typing reaches the remote shell again. Thanks @kays0x for the community fix.",
      },
      {
        title: "Command Palette Settings Toggles",
        description:
          "Boolean Settings rows are now reachable from the command palette, including iMessage Mode. Toggle features without opening Settings.",
      },
      {
        title: "Sidebar Reorder Stays in View",
        description:
          "Reordering a selected workspace now keeps it visible — the sidebar scrolls along so the selected item never disappears off-screen after a move.",
      },
      {
        title: "Cloud VM Error Guidance",
        description:
          "cmux vm errors now include actionable next steps: sign-in instructions when not authenticated, suggested fixes for unknown flags, and usage examples for missing arguments.",
      },
    ],
  },
  "0.64.5": {
    title: "Codex Teams, Menubar Global Search, Markdown Viewer, Feed by Default",
    features: [
      {
        title: "Codex Teams Subagent Panes",
        description:
          "cmux codex-teams now maps Codex's subagent sessions into native cmux panes, the same way claude-teams does for Claude Code. Spawned subagents stack in a right column with sidebar metadata and notifications routed through cmux.",
      },
      {
        title: "Menubar Global Search",
        description:
          "A new global search command surfaces windows, workspaces, panes, surfaces, and right-sidebar tools from the menu bar so you can jump anywhere without reaching for the sidebar.",
      },
      {
        title: "Rewritten Markdown Viewer",
        description:
          "The Markdown viewer now uses a webview-based renderer with richer formatting, better selection, and faster scrolling. Thanks @tobi for the contribution.",
      },
      {
        title: "Feed on by Default",
        description:
          "The Feed is now enabled by default for new and existing users, surfacing notifications, agent events, and workspace activity in one chronological stream.",
      },
      {
        title: "Quality-of-life Polish",
        description:
          "Open right sidebar tools as panes, workspace cwd inheritance, an unread defer shortcut, iMessage workspace ordering and previews, and right-sidebar CLI parity. Bug fixes for Korean IME arrows, garbled Chinese paste, Metal renderer crashes, terminal portal resize lag, multi-monitor sleep/wake window position, and Cloud VM SSH attach.",
      },
    ],
  },
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
