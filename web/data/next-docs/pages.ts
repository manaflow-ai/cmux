// Hand-written cmux-next docs pages (plans/cmux-next/docs-DESIGN.md). The CLI
// and settings reference pages are generated; see scripts/export-next-docs.ts.
// Keep these short and plain. Every command named here must exist in the
// action catalog; tests/next-docs.test.ts checks that.

export type DocBlock =
  | { h2: string }
  | { p: string }
  | { ul: string[] }
  | { code: string; lang?: string }
  | { note: string };

export interface NextDocPage {
  slug: string;
  navKey: string;
  title: string;
  description: string;
  /** Generated reference pages render a table after `body`. */
  generated?: "cli" | "settings" | "palette" | "shortcuts";
  /** Slugs of other cmux-next pages, shown as links after `body`. */
  links?: string[];
  body: DocBlock[];
}

export const nextDocPages: NextDocPage[] = [
  {
    slug: "getting-started",
    navKey: "nextGettingStarted",
    title: "Getting started with cmux-next",
    description: "What cmux-next is, how to install it, and how to update it.",
    body: [
      { p: "cmux-next is the rewrite of cmux: a Swift app shell, a Rust core, and web views for chat, diffs, Markdown, and Settings. It runs your terminals, browsers, and coding agents in one window, with Chief on the Home screen." },
      { note: "cmux-next is in preview. It changes every day. This page is built from the main branch, so it may be ahead of the build you run." },
      { h2: "Install" },
      { p: "Two builds exist. Pick one." },
      { ul: [
        "cmux NEXT DEV runs beside classic cmux. It updates after each green push to feat-cmux-next.",
        "nightly-next takes the place of classic cmux NIGHTLY (same bundle id and socket). It updates through Sparkle about every 30 to 60 minutes. Apple Silicon only.",
      ] },
      { h2: "Install cmux NEXT DEV" },
      { code: "curl -fsSL -o /tmp/update-dev-daily.sh \\\n  https://raw.githubusercontent.com/manaflow-ai/cmux/feat-cmux-next/scripts/cmux-next/update-dev-daily.sh\nbash /tmp/update-dev-daily.sh", lang: "bash" },
      { p: "The script downloads the build, checks its SHA-256 and bundle id, and installs ~/Applications/cmux NEXT DEV.app. Run the same command to update. If you have the newest build, it says so and does nothing." },
      { h2: "Install nightly-next" },
      { code: "gh release download nightly-next -R manaflow-ai/cmux -p '*macos-arm64*.dmg'", lang: "bash" },
      { p: "Open the DMG and drag the app to Applications. The app updates itself from then on." },
      { h2: "Coming from classic cmux" },
      { p: "The first launch brings over the last saved classic session once: workspaces, groups, panes, tabs, and Claude Code or Codex chats. Classic's files are only read. To run it again, use the command palette item Import Workspaces from Classic cmux, or run:" },
      { code: "cmux workspace import-classic", lang: "bash" },
      { h2: "First steps" },
      { ul: [
        "Press Cmd+Shift+P for the command palette. Every action in the app is there, with its shortcut.",
        "Open Home and ask Chief for what you want in plain words.",
        "Press Cmd+, for Settings. Every setting is also a key in ~/.config/cmux/cmux.json.",
        "Run cmux --help in a cmux terminal. The CLI can do everything the palette can.",
      ] },
      { h2: "Next" },
    ],
    links: ["home-and-chief", "workspaces", "command-palette", "cli"],
  },
  {
    slug: "updates",
    navKey: "nextUpdates",
    title: "Install, update, and nightly",
    description: "How cmux-next updates and how to check your build.",
    body: [
      { h2: "Updates" },
      { ul: [
        "nightly-next: the app checks the update feed and shows a Restart to Update card. Restart relaunches at once. Your terminals, agents, and chats come back.",
        "cmux NEXT DEV: run the update script again.",
      ] },
      { p: "Quitting keeps sessions by default. Agents keep running in the acpmux daemon while the app restarts." },
      { h2: "Check your build" },
      { code: "cmux version", lang: "bash" },
      { h2: "Server restarts" },
      { p: "When the app and the background server are on different versions, Settings > Server shows Restart Recommended. cmux never restarts the server on its own. You choose when." },
    ],
  },
  {
    slug: "home-and-chief",
    navKey: "nextHome",
    title: "Home and Chief",
    description: "The Home screen, Chief, and group chats.",
    body: [
      { p: "Home is the first screen. It looks like a messages app. Each row is a conversation: a Chief, a person on your team, or a group chat." },
      { p: "Chief is your assistant. You ask in plain words. Chief starts agents, opens panes, and reports back in the same thread." },
      { h2: "Commands" },
      { code: "cmux home open-chief      # open Chief\ncmux home tab             # open Home in a tab\ncmux home new-chief       # make another Chief\ncmux home send            # send a message", lang: "bash" },
      { h2: "Teammates" },
      { p: "People in your team show up as contacts. You can message one, or start a group chat with several people and Chiefs." },
      { p: "In a group chat, use Hide Alerts to mute, Pin/Unpin Conversation to keep it on top, and Leave Group to leave." },
    ],
  },
  {
    slug: "agents",
    navKey: "nextAgents",
    title: "Agents and subagents",
    description: "Run Claude Code, Codex, and other agents as chats.",
    body: [
      { p: "An agent runs as a chat tab. The chat shows messages, tool calls, and diffs. The agent itself lives in acpmux, a daemon, so it keeps running when the app closes." },
      { h2: "Start and stop" },
      { code: "cmux agent quick          # start an agent\ncmux agent new-chat       # new agent chat in this pane\ncmux agent stop-turn      # stop the current turn\ncmux agent archive-chat", lang: "bash" },
      { h2: "Fork a conversation" },
      { p: "A fork copies the conversation so you can try another path. Fork to the right, left, above, below, a new tab, or a new workspace." },
      { code: "cmux agent fork-conversation-to-right\ncmux agent fork-conversation-to-new-workspace", lang: "bash" },
      { h2: "Teams" },
      { code: "cmux agent launch-claude-teams\ncmux agent launch-codex-teams", lang: "bash" },
      { h2: "Subagents" },
      { p: "A subagent is an agent another agent started. It gets its own workspace and chat, so you can open it, read it, and stop it like any other." },
    ],
  },
  {
    slug: "workspaces",
    navKey: "nextWorkspaces",
    title: "Workspaces, panes, tabs, and groups",
    description: "How cmux-next lays out your work.",
    body: [
      { p: "A window holds workspaces. A workspace holds panes. A pane holds tabs: terminals, browsers, chats, files, and more." },
      { h2: "Panes" },
      { code: "cmux pane split-right\ncmux pane split-down\ncmux pane equalize-splits\ncmux pane move-to-new-workspace", lang: "bash" },
      { h2: "Tabs" },
      { code: "cmux tab new-terminal\ncmux tab new-browser\ncmux tab rename\ncmux tab move-to-pane-left", lang: "bash" },
      { h2: "Workspace groups" },
      { p: "Groups gather related workspaces in the sidebar. A group has a name, color, and icon. It can hold subgroups, and you can pin, collapse, or mark it read." },
      { code: "cmux workspace-group create\ncmux workspace-group add-workspace\ncmux workspace-group set-color\ncmux workspace-group collapse-all", lang: "bash" },
      { h2: "Hibernation" },
      { p: "A workspace you have not opened for a while hibernates: its pages and chats are unloaded to free memory. Terminals and agents keep running. Pinned workspaces, workspaces with running commands or agents, and workspaces you keep awake never hibernate. Change it with workspaces.hibernation.enabled and workspaces.hibernation.idleMinutes." },
    ],
    links: ["spaces", "command-palette"],
  },
  {
    slug: "spaces",
    navKey: "nextSpaces",
    title: "Spaces and columns",
    description: "Group windows and workspaces into spaces, and dock columns to the window.",
    body: [
      { p: "A space is a named set of windows and workspaces, for example Work and Personal. Each space has its own color, icon, theme, terminal defaults, and groups. The sidebar shows your spaces at the top or bottom (sidebar.showSpaces, sidebar.spacesPosition)." },
      { h2: "Switch spaces" },
      { p: "Use Next Space, Previous Space, or Select Space 1…9. The default keys are on the Keyboard shortcuts page. From the CLI:" },
      { code: "cmux space switch\ncmux space new-workspace\ncmux space new-window", lang: "bash" },
      { h2: "Change a space" },
      { code: "cmux space rename\ncmux space set-color\ncmux space set-icon\ncmux space set-theme\ncmux space set-defaults\ncmux space move-left\ncmux space delete", lang: "bash" },
      { p: "Set Space Terminal Defaults gives new terminals in the space their folder, shell, and environment. Set Space Theme changes the colors of every window in the space." },
      { h2: "Columns" },
      { p: "A column is a strip of panes. Dock a column to the left, right, top, or bottom of the window: it stays there when you switch workspaces. Float it to put it over the window, or undock it to put it back in the workspace." },
      { code: "cmux column dock-left\ncmux column dock-bottom\ncmux column float\ncmux column undock\ncmux column width-half\ncmux column center", lang: "bash" },
    ],
    links: ["workspaces", "keyboard-shortcuts"],
  },
  {
    slug: "command-palette",
    navKey: "nextPalette",
    title: "Command palette",
    description: "Every command in the palette, with its default shortcut and CLI command.",
    generated: "palette",
    body: [
      { p: "Press Cmd+Shift+P to open the command palette. Type a few letters of a command, then press Return. The palette also finds workspaces, tabs, files, and settings." },
      { p: "Start the query with a scope prefix to search one kind of thing. Set the prefixes in Settings > General (the palette.scopes keys)." },
      { code: "cmux palette open", lang: "bash" },
      { p: "This list is generated from the action catalog, the same catalog the app builds its palette, menus, CLI, and MCP tools from. A test fails when the catalog changes and this page does not." },
    ],
  },
  {
    slug: "browser",
    navKey: "nextBrowser",
    title: "Browser",
    description: "Browser tabs, profiles, and automation.",
    body: [
      { p: "Browser tabs open inside a pane. A tab can use Chromium or WebKit." },
      { code: "cmux tab new-browser\ncmux browser open-in-chromium\ncmux browser open-in-webkit\ncmux browser screenshot-page\ncmux browser import-cookies", lang: "bash" },
      { h2: "Profiles" },
      { p: "Browser profiles keep cookies and sign-ins apart. Manage them with the cmux browser-profile commands." },
      { h2: "Automation" },
      { p: "Agents drive browser tabs through the cmux CLI and MCP tools. See the CLI and MCP reference for the full list of browser verbs." },
    ],
  },
  {
    slug: "markdown",
    navKey: "nextMarkdown",
    title: "Markdown and files",
    description: "View and edit Markdown and other files in a pane.",
    body: [
      { p: "Markdown files open as rendered pages in a pane. Click a link in a terminal to open the file in the right viewer." },
      { code: "cmux file open", lang: "bash" },
      { p: "Other file types open in the editor or the file preview. Use Open Files as Pane to browse a folder beside your terminal." },
    ],
  },
  {
    slug: "cloud",
    navKey: "nextCloud",
    title: "Cloud machines",
    description: "Run workspaces on cloud machines.",
    body: [
      { p: "A cloud machine is a remote computer that cmux sets up for you. Run a workspace there, or move one over and bring it back." },
      { code: "cmux cloud new-machine\ncmux cloud new-workspace\ncmux cloud ssh\ncmux cloud exec\ncmux cloud move\ncmux cloud bring-back", lang: "bash" },
      { h2: "Terminals" },
      { p: "Open a terminal on a machine with ssh, or make a new workspace there. Pass --workspace with a workspace id to add a terminal tab to that workspace instead. When the terminal is open, both answer machine_id and workspace_id, plus the new terminal's surface_id when cmux knows it. A paused machine resumes first: if that takes longer than about 30 seconds the answer is pending (machine_id, resuming, pending) and the terminal still opens." },
      { code: "cmux cloud ssh --target machine:<id>\ncmux cloud new-terminal-on-machine --target machine:<id>\ncmux cloud new-terminal-on-machine --target machine:<id> --workspace <workspace-id>", lang: "bash" },
      { h2: "Start an agent on a machine" },
      { p: "Start a Claude or Codex session on a cloud machine. Name the machine with --target, or give a name with --name to use that machine or create it. An agent that runs this asks you first in its chat." },
      { code: "cmux cloud start-session --target machine:<id> --agent claude\ncmux cloud start-session --name dev --agent codex", lang: "bash" },
      { h2: "Fork, snapshot, hand off" },
      { code: "cmux cloud fork-machine\ncmux cloud snapshot-machine\ncmux cloud restore-machine\ncmux cloud hand-off-machine", lang: "bash" },
      { h2: "Ports and browser tabs" },
      { p: "Open a port of a machine in a cmux browser tab, or get its link. Name the machine with --target machine:<id>; cmux cloud list-machines lists the ids." },
      { code: "cmux cloud open-browser --target machine:<id> --port 3000\ncmux cloud machine-link --target machine:<id> --port 3000\ncmux cloud port-forward --target machine:<id> --port 3000\ncmux cloud port-list --target machine:<id>\ncmux cloud port-close --target machine:<id> --port 3000", lang: "bash" },
      { note: "Running machines do not update themselves. New software reaches new machines first." },
    ],
    links: ["remote", "plans"],
  },
  {
    slug: "remote",
    navKey: "nextRemote",
    title: "Remote machines and Tailscale",
    description: "Run workspaces and agents on your own machines over SSH or Tailscale.",
    body: [
      { p: "A remote machine is a computer you own: a Mac mini, a Linux box, or a server. cmux installs cmux-tui on it, starts its agent daemon, and shows its workspaces in your sidebar under the machine's name. Agents on it keep running when your laptop sleeps." },
      { h2: "Add a machine" },
      { p: "Open the command palette and run Add Machine…, or click + in the Machines part of the sidebar. Type a host name, or pick a device from your Tailscale network. cmux then:" },
      { ul: [
        "checks that it can reach the host with SSH keys (no passwords);",
        "installs cmux-tui on the host;",
        "copies your agent profiles across and starts the agent daemon;",
        "shows a checklist. Run it again at any time with Check Machine.",
      ] },
      { code: "cmux machine add\ncmux machine doctor\ncmux remote connect", lang: "bash" },
      { h2: "Tailscale" },
      { p: "When Tailscale runs on this Mac, Add Machine lists the online devices of your tailnet, and marks the ones that are already added. Only your own devices are probed. A teammate's machine shows only when they share it with you." },
      { p: "Connections go over SSH on your tailnet. cmux opens no public port." },
      { h2: "Work on a machine" },
      { code: "cmux remote new-workspace\ncmux remote open-terminal-here\ncmux remote reconnect\ncmux remote disconnect\ncmux remote forget", lang: "bash" },
      { p: "Browser tabs in a remote workspace can open the machine's localhost ports (browser.remoteLocalhost)." },
      { h2: "When it does not connect" },
      { ul: [
        "Run Check Machine. Each failed step says what to fix.",
        "Make sure ssh HOST works in a terminal without a password.",
        "Run Copy SSH Error from the command palette to get the full message.",
      ] },
    ],
    links: ["cloud"],
  },
  {
    slug: "plans",
    navKey: "nextPlans",
    title: "Plans and credits",
    description: "What is free, what costs money, and how cmux credits work.",
    body: [
      { note: "Paid plans for cmux-next are in preview and not on sale yet. Prices and limits can change before launch. This page says how billing works, not what it costs." },
      { h2: "Free" },
      { ul: [
        "The app, the CLI, terminals, browser tabs, remote machines, and Home are free.",
        "Agents that use your own Claude Code or Codex sign-in, or your own API key, are free. cmux does not meter them or see their bill.",
      ] },
      { h2: "cmux credits" },
      { p: "cmux credits pay for what cmux runs for you: models through cmux inference, and cloud machine time. One credit is one US dollar. Buy credits in the app; they work with or without a plan." },
      { p: "When an agent's model needs a key you do not have, the chat shows a card with three choices: add your own API key, use cmux credits, or add credits." },
      { h2: "Plans" },
      { p: "A paid plan adds included credits each month, more cloud machines at once, and larger machines. Team plans pool the included credits of all seats. Use above the included amount is charged at cost or taken from prepaid credits." },
      { h2: "See your usage" },
      { p: "Open the command palette and run Chief Usage, or Upgrade to cmux Pro to see the plans. Your accounts and sign-ins are in Accounts:" },
      { code: "cmux accounts show", lang: "bash" },
    ],
    links: ["cloud"],
  },
  {
    slug: "keyboard-shortcuts",
    navKey: "nextShortcuts",
    title: "Keyboard shortcuts",
    description: "Default keyboard shortcuts in cmux-next.",
    body: [
      { p: "These are the default shortcuts. The list is generated from the action catalog, so it matches the app. Your own bindings are in Settings > Keyboard Shortcuts." },
      { p: "Rebind any action by id in cmux.json under shortcuts.bindings:" },
      { code: "{\n  \"shortcuts\": { \"bindings\": { \"commandPalette\": \"cmd+shift+p\" } }\n}", lang: "json" },
    ],
    generated: "shortcuts",
    links: ["command-palette"],
  },
  {
    slug: "cli",
    navKey: "nextCli",
    title: "CLI and MCP reference",
    description: "Every cmux CLI command and which are also MCP tools.",
    generated: "cli",
    body: [
      { p: "Every action in the app can run from the CLI. This page is generated from the action catalog. It cannot drift: a test fails when the catalog changes and this page does not." },
      { code: "cmux <noun> <verb>\ncmux action list\ncmux action run <id>", lang: "bash" },
      { p: "A verb marked no under MCP tool is CLI only, because it needs credentials, ends the app, changes the system, or only moves focus." },
    ],
    links: ["mcp"],
  },
  {
    slug: "mcp",
    navKey: "nextMcp",
    title: "MCP server",
    description: "Give Claude Code, Codex, or any MCP client control of cmux.",
    body: [
      { p: "cmux mcp serve gives an MCP client the same control of cmux that the CLI has. It talks JSON-RPC on stdin and stdout; nothing listens on the network. Agent chats inside cmux have it already." },
      { h2: "Turn it on" },
      { p: "For clients outside cmux, the server is off until you turn it on:" },
      { code: "cmux settings set mcp.enabled true\ncmux mcp tools", lang: "bash" },
      { h2: "Claude Code" },
      { code: "claude mcp add cmux -- cmux mcp serve", lang: "bash" },
      { h2: "Codex" },
      { code: "# ~/.codex/config.toml\n[mcp_servers.cmux]\ncommand = \"cmux\"\nargs = [\"mcp\", \"serve\"]", lang: "toml" },
      { p: "When cmux is not on the client's PATH, use the one in the app: /Applications/cmux.app/Contents/Resources/bin/cmux." },
      { h2: "Tools" },
      { p: "By default the server offers two tools: cmux_docs searches every cmux tool, and cmux_exec runs a short script that calls them. This keeps the client's tool list small. With --all-tools it offers every tool directly:" },
      { ul: [
        "one tool per app action, named app_ and the CLI words (cmux workspace rename is app_workspace_rename). The CLI and MCP reference lists each name;",
        "tools for workspaces, panes, tabs, terminals, and git (workspace_list, terminal_input_write, git_status);",
        "browser tools (browser_navigate, browser_repl_eval) and agent tools (agents_snapshot, agents_wait).",
      ] },
      { code: "cmux mcp serve --all-tools\ncmux mcp tools --json", lang: "bash" },
      { p: "cmux mcp tools --json lists every tool with its input schema, and every action it leaves out with the reason. A tool never steals focus unless its purpose is focus." },
    ],
    links: ["cli"],
  },
  {
    slug: "settings",
    navKey: "nextSettings",
    title: "Settings reference",
    description: "Every setting, its key, and its default.",
    generated: "settings",
    body: [
      { p: "Open Settings with Cmd+, or edit ~/.config/cmux/cmux.json. The key below is the path in that file: dots go one level down." },
      { code: "{\n  \"history\": { \"commandRetentionDays\": 30 }\n}", lang: "json" },
      { p: "This page is generated from the settings schema, so it matches the app." },
    ],
  },
];

export function nextDocPage(slug: string): NextDocPage | undefined {
  return nextDocPages.find((page) => page.slug === slug);
}

/** The anchor id of a heading, shared by the page renderer and docs search. */
export function headingId(text: string): string {
  return text.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
}

/** The docs path of a cmux-next page; Getting started is the track's index. */
export function nextDocHref(slug: string): string {
  return slug === "getting-started" ? "/docs/next" : `/docs/next/${slug}`;
}
