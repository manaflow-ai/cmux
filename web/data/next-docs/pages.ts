// Hand-written cmux-next docs pages (plans/cmux-next/docs-DESIGN.md). The CLI
// and settings reference pages are generated; see scripts/export-next-docs.ts.
// Keep these short and plain. Every command named here must exist in the
// action catalog; tests/next-docs.test.ts checks that.

export type DocBlock =
  | { h2: string }
  | { p: string }
  | { ul: string[] }
  | { code: string; lang?: string }
  | { note: string }
  /** Places in the repository, each linked to its source; a test checks each path exists and is that kind. */
  | { files: { path: string; kind: "file" | "folder"; what: string }[] };

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
        "Press Cmd+, for Settings. Every setting is also a key in ~/.config/cmux/cmux-next.json.",
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
      { p: "A fork copies the conversation so you can try another path. Fork to the right, left, above, below, a new column on either side, a new row, a new tab, a new workspace, or a new window." },
      { code: "cmux agent fork-conversation-to-right\ncmux agent fork-conversation-to-new-column-right\ncmux agent fork-conversation-to-new-workspace", lang: "bash" },
      { h2: "Teams" },
      { code: "cmux agent launch-claude-teams\ncmux agent launch-codex-teams", lang: "bash" },
      { h2: "Subagents" },
      { p: "A subagent is an agent another agent started. It gets its own workspace and chat, so you can open it, read it, and stop it like any other." },
    ],
    links: ["own-keys", "open-models", "agent-spend"],
  },
  {
    slug: "own-keys",
    navKey: "nextOwnKeys",
    title: "Run agents on your own API keys",
    description: "Use your own API key, your cloud provider, or your own model endpoint for Claude Code, Codex, and other agents in cmux.",
    body: [
      { p: "Yes: cmux runs Claude Code, Codex, and other agents on your own API keys, and the key's own account is billed. cmux does not meter these agents or see their bill." },
      { h2: "How do I use my own API key with Claude Code in cmux?" },
      { p: "cmux reads your key the way Claude Code does, so a key that works in your terminal works in cmux. Pick one of three ways." },
      { ul: [
        "From your shell. Export ANTHROPIC_API_KEY in ~/.zprofile or ~/.zshrc. The agent daemon reads your login shell, so every Claude Code chat gets the ANTHROPIC_* and CLAUDE_* variables your terminal has. A change to those files applies to the next chat you start. An apiKeyHelper in Claude Code's settings.json works too.",
        "From a chat. When Claude Code is not signed in, the chat's sign-in card has Use an API key. cmux saves the key where Claude Code reads it (env.ANTHROPIC_API_KEY in Claude Code's settings.json) and starts the chat again on it.",
        "For one chat. In the model picker, choose Add account…, then Use an API key. Give where the key is, not the key: keychain:NAME, env:VARIABLE, or file:/absolute/path. Then pick that account in any chat. Other chats keep their own account.",
      ] },
      { code: "# ~/.zprofile\nexport ANTHROPIC_API_KEY=your-key", lang: "bash" },
      { h2: "How do I use Claude through my cloud provider?" },
      { p: "Turn on Claude Code's own provider switch in your login shell. cmux passes it to every Claude Code chat. It passes the provider's credential and region variables too, but only when your own switch is on." },
      { code: "# ~/.zprofile: one of these, with the provider's usual variables\nexport CLAUDE_CODE_USE_BEDROCK=1   # AWS_REGION, AWS_PROFILE, ...\nexport CLAUDE_CODE_USE_VERTEX=1    # CLOUD_ML_REGION, ANTHROPIC_VERTEX_PROJECT_ID, ...\nexport CLAUDE_CODE_USE_FOUNDRY=1", lang: "bash" },
      { p: "Claude Code's own setup for each provider works as it does in a terminal. cmux only passes the variables through." },
      { h2: "How do I use Codex with an API key?" },
      { p: "Codex keeps its API key in its own login. When Codex is not signed in, the chat's sign-in card has Use an API key: cmux runs codex login --with-api-key and gives it the key on stdin, so the key is never on a command line. In a terminal, the same step is:" },
      { code: "printenv OPENAI_API_KEY | codex login --with-api-key", lang: "bash" },
      { p: "OPENAI_* and CODEX_* variables in your login shell reach Codex chats too." },
      { h2: "How do I connect my own model endpoint?" },
      { p: "An endpoint that speaks Claude's Messages API, or the Chat Completions API (OpenAI-compatible), becomes an agent with one command. It can be a company gateway, a team inference server, or a model server on this Mac." },
      { code: "# Messages API, run through Claude Code\ncmux harness add gateway --example anthropic-endpoint --base-url https://llm.example.com --model MODEL\ncmux harness secret set gateway ANTHROPIC_AUTH_TOKEN\ncmux harness doctor gateway\n\n# Chat Completions API (compatible endpoint), run through OpenCode\ncmux harness add local --example openai-endpoint --base-url http://127.0.0.1:8080/v1 --model MODEL\ncmux harness secret set local CMUX_BYO_API_KEY\ncmux harness doctor local", lang: "bash" },
      { ul: [
        "secret set asks for the key without showing it, or reads it from stdin. It keeps the key in the Keychain on macOS (secret-tool on Linux). The agent's profile file holds only the item's name.",
        "The base URL must use https. Plain http works only to localhost, 127.0.0.1, or ::1.",
        "doctor sends one real prompt. When it fails, it says what to fix: the key, the base URL, or the model id.",
        "The new agent shows in the model picker. Your own Claude sign-in and ANTHROPIC_* variables never redirect it.",
        "A compatible endpoint runs through OpenCode, so install OpenCode first.",
      ] },
      { h2: "How do I give an agent on a Cloud machine my key?" },
      { ul: [
        "Claude Code and Codex: when a Cloud chat is not signed in, its sign-in card offers to sign in to Claude or Codex, or Use an API key. Either one signs in that machine only. Your Mac's login stays on your Mac.",
        "Other keys a repository's machine needs: list their names under [secrets] in the repository's .cmux/machine.toml, then store each value on your Mac with cmux cloud secret set. The value stays in your Mac's Keychain and goes to the machine only over its own connection. Names that would send agents elsewhere (ANTHROPIC_API_KEY, ANTHROPIC_BASE_URL, OPENAI_API_KEY, OPENAI_BASE_URL, and others) are refused there.",
      ] },
      { code: "cmux cloud secret set MY_SERVICE_KEY", lang: "bash" },
      { p: "On machines you add yourself, your vault can keep a key out of the agent's reach. Agents get a placeholder (cmux-secret://NAME), and the machine adds the real value only to requests to the hosts you list:" },
      { code: "cmux machine vault set MY_SERVICE_KEY --host api.example.com\ncmux machine vault grant MACHINE", lang: "bash" },
      { h2: "Does cmux keep prompt caching on with my own key?" },
      { p: "Yes. cmux never turns prompt caching off, and it starts every Claude Code chat on the one-hour cache. By itself, Claude Code uses the five-minute cache with an API key, your own endpoint, or a cloud provider: after a pause of more than five minutes, the whole prompt is written again. With the one-hour cache, a chat you come back to within the hour reads its prompt from the cache." },
      { p: "Writes to the one-hour cache cost a little more than writes to the five-minute one. To use five minutes:" },
      { code: "cmux settings set agents.promptCache 5m", lang: "bash" },
      { p: "The setting applies to chats you start after the change. A cache variable you set yourself (CLAUDE_CODE_PROMPT_CACHE_TTL, FORCE_PROMPT_CACHING_5M, DISABLE_PROMPT_CACHING) wins over it." },
    ],
    links: ["agent-spend", "open-models", "plans", "cloud"],
  },
  {
    slug: "agent-spend",
    navKey: "nextAgentSpend",
    title: "Audit agent spend",
    description: "See what every agent turn on this Mac cost, by session, workspace, repository, pull request, day, person, provider, or model.",
    body: [
      { p: "The Costs tab in Agent History shows what every agent on this Mac spent, whichever agent ran it, grouped the way you choose." },
      { h2: "Where do I see what my agents cost?" },
      { p: "Open the command palette, run Show Agent History, and pick the Costs tab. It reads the cost ledger of this Mac's agent daemon, which adds up each turn when the turn ends. So the tab opens at once, however many chats you have." },
      { h2: "What does the Costs tab show?" },
      { ul: [
        "A range: 24 hours, 7 days, 30 days, or all time.",
        "Totals for the range: cost, tokens in, tokens out, turns, tool calls, and agent time.",
        "One row per group, most spent first, with a bar for its share: cost, tokens in and out, turns, and agent time.",
        "Tokens in counts uncached input and cache writes. Cache reads are the same context sent again, so they are not counted.",
      ] },
      { h2: "How do I group agent spend by repository, pull request, or person?" },
      { p: "Pick a group: session, workspace, repository, pull request, day, person, provider, or model. cmux adds a session's pull requests as they open, so a pull request's row adds up every session that worked on it. Person is the user and machine that ran the agent." },
      { h2: "Where does each cost come from?" },
      { p: "Each cost is marked with its source:" },
      { ul: [
        "Reported by the agent: the agent's own figure for the turn.",
        "Priced from the table: the turn's tokens at the price table that ships with cmux. The tab shows the table's version.",
        "Partly priced: a group whose turns had different sources, such as some reported and some from the table, or some with no price.",
        "No price known: no turn had a price, because the table does not list the model.",
      ] },
      { p: "A turn with no price adds nothing to the cost. When the tab counts turns with no price, the cost shown for that range or group is incomplete: the real cost is at least that much." },
      { p: "A table price is an estimate at list prices, not a bill. On a subscription, the figure is what the same tokens would cost on the API, not what you pay. A fork's copy of its parent's turns counts once, in the parent." },
      { h2: "Can I read agent spend from the command line?" },
      { code: "cmux acp ledger                              # the last 7 days, by repository\ncmux acp ledger --since 30d --by pr          # the last 30 days, by pull request\ncmux acp ledger --since 1d --by model --json # today, by model, as JSON", lang: "bash" },
      { p: "--by takes repo, pr, day, person, workspace, vendor, model, or account. --since takes a length such as 30m, 6h, or 7d." },
      { h2: "What does it cover?" },
      { p: "Every turn that ran on this Mac's agent daemon, with any agent: Claude Code, Codex, or one you added. Each machine keeps its own ledger. Run cmux acp ledger on a machine to read that machine's." },
    ],
    links: ["own-keys", "plans", "agents"],
  },
  {
    slug: "open-models",
    navKey: "nextOpenModels",
    title: "Open-weight models",
    description: "Run coding agents in cmux on open-weight models: on this Mac, on your own GPU machine, or on a server your team runs.",
    body: [
      { p: "Point an agent at any server that speaks the Chat Completions API (OpenAI-compatible), on this Mac, on your own GPU machine, or on your team's inference server, and it runs in cmux like Claude Code or Codex." },
      { h2: "Which agents in cmux can run open-weight models?" },
      { p: "Any agent whose models come from providers you set up. cmux knows OpenCode and Pi out of the box: install one and it shows in the model picker, using the providers you set up for it in your terminal. Add any other agent that speaks ACP in Settings > Agents, or with:" },
      { code: "cmux agent add-harness", lang: "bash" },
      { p: "The simplest path is your own endpoint, below: one command makes the agent, and cmux keeps its key in the Keychain." },
      { h2: "How do I run an agent on a model server on my Mac?" },
      { p: "Start the model server, then add it as an agent. Local servers usually listen on localhost and serve the Chat Completions API under /v1." },
      { code: "cmux harness add local --example openai-endpoint --base-url http://127.0.0.1:8080/v1 --model MODEL\ncmux harness secret set local CMUX_BYO_API_KEY\ncmux harness doctor local", lang: "bash" },
      { ul: [
        "MODEL is the id the server lists for the model.",
        "A server that takes no key still needs a value stored. Any text works.",
        "This agent runs through OpenCode, so install OpenCode first.",
        "doctor sends one real prompt. A first prompt can wait while the server loads the model. doctor waits up to 120 seconds per step; --timeout gives it longer.",
      ] },
      { h2: "How do I use a model server on my own GPU machine?" },
      { p: "Two ways. Neither puts the server on the public internet." },
      { p: "Agent on your Mac, model on the GPU machine: forward the server's port over SSH, then add the forwarded address as above. A server with its own https address works directly with that address." },
      { code: "ssh -N -L 8080:127.0.0.1:8080 gpu-box", lang: "bash" },
      { p: "Agent and model both on the GPU machine: add the machine to cmux (Add Machine… in the command palette, or the command below). Then, on that machine, add the endpoint at its own localhost." },
      { code: "cmux acp machine enroll gpu-box\n\n# then, on gpu-box:\nacpmux harness add local --example openai-endpoint --base-url http://127.0.0.1:8080/v1 --model MODEL\nacpmux harness secret set local CMUX_BYO_API_KEY\nacpmux harness doctor local", lang: "bash" },
      { p: "On Linux, harness secret set stores the key with secret-tool, so the machine needs a running secret service. Then start a chat on that machine (cmux remote new-workspace) and pick local in the model picker." },
      { h2: "How do I use my team's inference server?" },
      { p: "Add it with its https address and the key your team gives you. cmux refuses plain http to anything but localhost, so a server without https needs a forwarded port, as above." },
      { code: "cmux harness add team --example openai-endpoint --base-url https://llm.example.com/v1 --model MODEL\ncmux harness secret set team CMUX_BYO_API_KEY\ncmux harness doctor team", lang: "bash" },
      { h2: "Can a Cloud machine run an open-weight model?" },
      { p: "Not yet: Cloud machines have no GPU today. Run the model on your own machine or on a server your team runs. cmux inference also serves open-weight models, paid with cmux credits." },
    ],
    links: ["own-keys", "remote", "plans"],
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
    links: ["cloud", "own-keys", "agent-spend"],
  },
  {
    slug: "keyboard-shortcuts",
    navKey: "nextShortcuts",
    title: "Keyboard shortcuts",
    description: "Default keyboard shortcuts in cmux-next.",
    body: [
      { p: "These are the default shortcuts. The list is generated from the action catalog, so it matches the app. Your own bindings are in Settings > Keyboard Shortcuts." },
      { p: "Rebind any action by id in ~/.config/cmux/cmux-next.json under shortcuts.bindings:" },
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
      { p: "Open Settings with Cmd+, or edit ~/.config/cmux/cmux-next.json. The key below is the path in that file: dots go one level down." },
      { code: "{\n  \"history\": { \"commandRetentionDays\": 30 }\n}", lang: "json" },
      { p: "This page is generated from the settings schema, so it matches the app." },
    ],
  },
  {
    slug: "architecture",
    navKey: "nextArchitecture",
    title: "Architecture",
    description: "How cmux-next fits together, and where each part lives in the code.",
    body: [
      { p: "cmux-next has three layers: a Swift app for macOS, a Rust core, and web views. The Rust core runs as daemons, so terminals and agents keep running when the app quits, updates, or crashes. Each section below links to the code and to the longer docs next to it." },
      { h2: "The app" },
      { p: "The macOS app is a Swift package with one module per feature: terminal, browser, Home, Settings, and so on. It draws windows, panes, and tabs, and draws terminals with libghostty from the ghostty-next fork. Rust code that runs inside the app is linked in as one static library." },
      { files: [
        { path: "Packages/macOS/CmuxNext", kind: "folder", what: "The app, one module per feature" },
        { path: "Packages/macOS/CmuxNext/Sources/CmuxNextTerminal", kind: "folder", what: "Terminal views on libghostty" },
        { path: "cmux-tui/crates/cmux-app-ffi", kind: "folder", what: "The Rust library inside the app" },
        { path: "ghostty-next", kind: "folder", what: "The Ghostty fork that renders terminals" },
        { path: "skills/cmux-architecture/SKILL.md", kind: "file", what: "Layering and package rules for Swift code" },
      ] },
      { h2: "The core: cmux-tui" },
      { p: "cmux-tui is the Rust core and the cmux command. Its daemon keeps the tree of machines, workspaces, panes, tabs, terminals, and browsers, and owns every shell. The app, the CLI, the terminal UI, and remote clients all talk to it over the same socket protocol. A new app build takes over the running daemon, which is why an update keeps your shells and scrollback." },
      { files: [
        { path: "cmux-tui", kind: "folder", what: "The Rust workspace: core, CLI, and daemons" },
        { path: "cmux-tui/crates/cmux-tui", kind: "folder", what: "The cmux command and its daemon" },
        { path: "cmux-tui/crates/cmux-tui-core", kind: "folder", what: "The workspace tree and the resources in it" },
        { path: "cmux-tui/spec/resource-api-v2.md", kind: "file", what: "The socket protocol (cmux.protocol/2)" },
        { path: "cmux-tui/docs", kind: "folder", what: "cmux-tui docs: concepts, remote, protocol" },
      ] },
      { h2: "Agents: acpmux" },
      { p: "acpmux is a daemon that keeps coding agents alive as named sessions: Claude Code, Codex, OpenCode, Pi, and any agent that speaks the Agent Client Protocol (ACP). It records every message, so any number of clients can attach to a session, and it adds up what each turn cost. A chat tab in the app is one of those clients." },
      { files: [
        { path: "cmux-tui/crates/acpmux", kind: "folder", what: "The agent daemon and its CLI" },
        { path: "webviews/src/agent-session/acpmux", kind: "folder", what: "The chat pane, a client of acpmux" },
      ] },
      { h2: "Web views" },
      { p: "Chat, diffs, Markdown, Settings, Home, and the other pages are React, built from one source tree. The app serves each page from its own cmux-page:// origin, and the page talks to the app only over a small bridge. A dev server can feed them to a running app with hot reload." },
      { files: [
        { path: "webviews", kind: "folder", what: "The React source and its dev server" },
        { path: "webviews/src/pages", kind: "folder", what: "Pages the app hosts: Settings, Home, history, and more" },
      ] },
      { h2: "One catalog for every action" },
      { p: "Every action is declared once in a Rust catalog: its title, shortcut, arguments, and where it shows up. The command palette, the menus, the cmux command, and the MCP tools are all built from it, and so are the CLI, palette, and keyboard shortcut pages of these docs. Settings work the same way, from one schema." },
      { files: [
        { path: "cmux-tui/crates/cmux-action-catalog", kind: "folder", what: "The action catalog" },
        { path: "plans/cmux-next/action-surfaces.json", kind: "file", what: "The catalog exported as JSON" },
        { path: "schemas/settings/settings-schema.json", kind: "file", what: "The settings schema" },
        { path: "cmux-tui/crates/cmux-tui/src/cli/mcp", kind: "folder", what: "The MCP server (cmux mcp serve)" },
      ] },
      { h2: "Other machines" },
      { p: "A remote machine runs the same cmux-tui and acpmux, so its workspaces and agents work like local ones. Cloud machines are remote machines that cmux sets up for you." },
      { files: [
        { path: "cmux-tui/crates/cmux-remote", kind: "folder", what: "The remote runtime: daemon, client, and connection" },
        { path: "cmux-tui/docs/remote.md", kind: "file", what: "How the remote daemon and clients connect" },
      ] },
      { h2: "Design docs" },
      { p: "Longer docs live next to the code. Design notes for each feature are in plans/cmux-next, and how-to guides for running and building cmux-next are in docs/cmux-next." },
      { files: [
        { path: "plans/cmux-next", kind: "folder", what: "Design notes, one per feature" },
        { path: "docs/cmux-next", kind: "folder", what: "Guides: install, dev builds, hot reload, dotfiles" },
        { path: "plans/cmux-next/docs-DESIGN.md", kind: "file", what: "How these docs are built" },
      ] },
    ],
    links: ["cli", "mcp", "settings"],
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
/** Where a repository path of a `files` block opens on GitHub: a file under blob, a folder under tree. */
export function repoSourceHref(path: string, kind: "file" | "folder"): string {
  return `https://github.com/manaflow-ai/cmux/${kind === "file" ? "blob" : "tree"}/feat-cmux-next/${path}`;
}

export function nextDocHref(slug: string): string {
  return slug === "getting-started" ? "/docs/next" : `/docs/next/${slug}`;
}

/**
 * The public path of a cmux-next page on cmux.com. Only the nightly docs zone
 * serves these pages, under /docs/nightly/next (/docs/next redirects there).
 */
export function nextDocPublicPath(slug: string): string {
  return nextDocHref(slug).replace(/^\/docs/, "/docs/nightly");
}
