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
  generated?: "cli" | "settings";
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
      { h2: "Next" },
      { ul: ["Home and Chief", "Agents and subagents", "Workspaces, panes, and tabs"] },
    ],
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
      { h2: "Spaces and columns" },
      { p: "A space is a named set of windows and workspaces with its own theme. Columns are dockable strips of panes: dock them left, right, top, or bottom, or float them." },
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
      { h2: "Fork, snapshot, hand off" },
      { code: "cmux cloud fork-machine\ncmux cloud snapshot-machine\ncmux cloud restore-machine\ncmux cloud hand-off-machine", lang: "bash" },
      { h2: "Ports and browser tabs" },
      { p: "Open a port of a machine in a cmux browser tab, or get its link. Name the machine with --target machine:<id>; cmux cloud list-machines lists the ids." },
      { code: "cmux cloud open-browser --target machine:<id> --port 3000\ncmux cloud machine-link --target machine:<id> --port 3000\ncmux cloud port-forward --target machine:<id> --port 3000\ncmux cloud port-list --target machine:<id>\ncmux cloud port-close --target machine:<id> --port 3000", lang: "bash" },
      { note: "Running machines do not update themselves. New software reaches new machines first." },
    ],
  },
  {
    slug: "keyboard-shortcuts",
    navKey: "nextShortcuts",
    title: "Keyboard shortcuts",
    description: "Default keyboard shortcuts in cmux-next.",
    body: [
      { p: "The shortcut list is generated from the action catalog, so it always matches the app. It is on the main docs page." },
      { p: "Rebind any action by id in cmux.json under shortcuts.bindings. Open the command palette with the keys shown in Settings > Keyboard." },
    ],
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
      { p: "Run cmux mcp serve to give an agent the same verbs as MCP tools. A verb marked no under MCP is CLI only, because it needs credentials, ends the app, or changes the system." },
    ],
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
