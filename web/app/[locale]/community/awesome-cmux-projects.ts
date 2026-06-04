export type AwesomeCmuxProject = {
  name: string;
  url: string;
  agent?: string;
  description: string;
  language?: string;
  stars?: number;
  categories: readonly string[];
};

export const awesomeCmuxSourceUrl = "https://github.com/manaflow-ai/awesome-cmux";
export const awesomeCmuxProjectRows = 150;

export const awesomeCmuxCategoryOrder = [
  "Sidebar & Status Pills",
  "Progress Bars & Estimation",
  "Sidebar Logs & Activity Feed",
  "Desktop Notifications",
  "Multi-Agent Orchestration",
  "Browser Automation",
  "Worktrees & Workspace Management",
  "Monitoring & Session Restore",
  "Remote & Mobile Access",
  "Themes, Layouts & Config",
  "Claude Code",
  "Pi",
  "OpenCode",
  "Copilot & Amp",
  "Multi-Agent / Agent-Agnostic",
  "Build & Distribution"
] as const;

export const awesomeCmuxProjects = [
  {
    "name": "Yeachan-Heo/oh-my-claudecode",
    "url": "https://github.com/Yeachan-Heo/oh-my-claudecode",
    "agent": "Claude Code",
    "description": "Use cmux native CLI commands to spawn, send to, capture, and close visible worker panes when Claude Code runs with CMUX_SURFACE_ID",
    "language": "TypeScript",
    "stars": 32659,
    "categories": [
      "Multi-Agent Orchestration",
      "Sidebar Logs & Activity Feed",
      "Claude Code"
    ]
  },
  {
    "name": "kdcokenny/opencode-worktree",
    "url": "https://github.com/kdcokenny/opencode-worktree",
    "agent": "OpenCode",
    "description": "Create OpenCode worktrees that detect CMUX_WORKSPACE_ID and launch/focus dedicated cmux workspaces through native cmux commands",
    "language": "TypeScript",
    "stars": 504,
    "categories": [
      "Worktrees & Workspace Management",
      "OpenCode"
    ]
  },
  {
    "name": "HazAT/pi-interactive-subagents",
    "url": "https://github.com/HazAT/pi-interactive-subagents",
    "agent": "Multi",
    "description": "Render a live TUI widget that tracks elapsed time and per-sub-agent progress while Claude Code orchestrates work across multiplexer panes - distinct from dashboard tools in that it surfaces timing and completion percentage, not session state",
    "language": "TypeScript",
    "stars": 429,
    "categories": [
      "Progress Bars & Estimation",
      "Multi-Agent Orchestration",
      "Monitoring & Session Restore",
      "Pi",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "kdcokenny/opencode-workspace",
    "url": "https://github.com/kdcokenny/opencode-workspace",
    "agent": "OpenCode",
    "description": "Bundle OpenCode workspace, notify, and worktree components that can write cmux status, send cmux notifications, and launch cmux workspaces",
    "language": "TypeScript",
    "stars": 402,
    "categories": [
      "Sidebar & Status Pills",
      "Desktop Notifications",
      "Worktrees & Workspace Management",
      "OpenCode"
    ]
  },
  {
    "name": "aannoo/hcom",
    "url": "https://github.com/aannoo/hcom",
    "agent": "Multi",
    "description": "Coordinate agents across terminal backends with a cmux preset that creates and closes cmux workspaces for visible sessions",
    "language": "Rust",
    "stars": 252,
    "categories": [
      "Multi-Agent Orchestration",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "kdcokenny/opencode-notify",
    "url": "https://github.com/kdcokenny/opencode-notify",
    "agent": "OpenCode",
    "description": "Deliver native OS notifications on completion, errors, and input-needed events with click-to-foreground, quiet hours, and custom sounds; the only standalone OpenCode notifier with quiet-hours scheduling and sound customization",
    "language": "TypeScript",
    "stars": 184,
    "categories": [
      "Desktop Notifications",
      "OpenCode"
    ]
  },
  {
    "name": "espennilsen/pi",
    "url": "https://github.com/espennilsen/pi",
    "agent": "Pi",
    "description": "Extends Pi with 7 LLM-callable tools for workspace and browser control stored in a version-controlled home directory, adding capabilities beyond sidebar status that no other Pi plugin matches",
    "language": "TypeScript",
    "stars": 102,
    "categories": [
      "Sidebar & Status Pills",
      "Multi-Agent Orchestration",
      "Pi"
    ]
  },
  {
    "name": "w-winter/dot314",
    "url": "https://github.com/w-winter/dot314",
    "agent": "Pi",
    "description": "Unlike single-script Pi plugins, ships as a curated extension collection that adds cost and token stats alongside sidebar state and workspace renaming - focuses on financial visibility other Pi plugins lack",
    "language": "TypeScript",
    "stars": 95,
    "categories": [
      "Sidebar & Status Pills",
      "Desktop Notifications",
      "Multi-Agent Orchestration",
      "Pi"
    ]
  },
  {
    "name": "burggraf/pi-teams",
    "url": "https://github.com/burggraf/pi-teams",
    "agent": "Pi",
    "description": "Run Pi teams through a cmux adapter that opens workspaces, creates splits, respawns panes, and closes surfaces from team workflows",
    "language": "TypeScript",
    "stars": 91,
    "categories": [
      "Multi-Agent Orchestration",
      "Worktrees & Workspace Management",
      "Pi"
    ]
  },
  {
    "name": "0xCaso/opencode-cmux",
    "url": "https://github.com/0xCaso/opencode-cmux",
    "agent": "OpenCode",
    "description": "Notify on permission requests and subagent activity scoped per workspace with unread marks; uniquely tracks unread notification state per workspace - alerts persist until explicitly acknowledged",
    "language": "TypeScript",
    "stars": 42,
    "categories": [
      "Sidebar & Status Pills",
      "Progress Bars & Estimation",
      "Sidebar Logs & Activity Feed",
      "Desktop Notifications",
      "OpenCode"
    ]
  },
  {
    "name": "hummer98/using-cmux",
    "url": "https://github.com/hummer98/using-cmux",
    "agent": "Claude Code",
    "description": "Teach Claude Code to own and drive sidebar progress bars as documented skill within a broader sub-agent lifecycle curriculum, making progress control an explicit agent capability rather than an implicit side-effect",
    "language": "Shell",
    "stars": 33,
    "categories": [
      "Progress Bars & Estimation",
      "Desktop Notifications",
      "Multi-Agent Orchestration",
      "Claude Code"
    ]
  },
  {
    "name": "drolosoft/cmux-resurrect",
    "url": "https://github.com/drolosoft/cmux-resurrect",
    "description": "Save and restore full workspaces including splits, CWDs, running commands, and Markdown workspace blueprints with dry-run preview - blueprint export makes rebuilding layouts reproducible without relying on session IDs",
    "language": "Go",
    "stars": 31,
    "categories": [
      "Monitoring & Session Restore",
      "Themes, Layouts & Config"
    ]
  },
  {
    "name": "AtAFork/ghostty-claude-code-session-restore",
    "url": "https://github.com/AtAFork/ghostty-claude-code-session-restore",
    "agent": "Claude Code",
    "description": "Restore Claude Code sessions in Ghostty or cmux by mapping CMUX_WORKSPACE_ID and replaying sessions with cmux list/send/send-key flows",
    "language": "Python",
    "stars": 23,
    "categories": [
      "Monitoring & Session Restore",
      "Claude Code"
    ]
  },
  {
    "name": "azu/cmux-hub",
    "url": "https://github.com/azu/cmux-hub",
    "agent": "Claude Code",
    "description": "Open a syntax-highlighted diff viewer in a browser split with inline review comments and live GitHub CI status alongside the terminal - the only browser plugin combining code review and CI feedback in one pane",
    "language": "TypeScript",
    "stars": 23,
    "categories": [
      "Sidebar & Status Pills",
      "Browser Automation",
      "Claude Code"
    ]
  },
  {
    "name": "untra/operator",
    "url": "https://github.com/untra/operator",
    "agent": "Multi",
    "description": "Present a kanban TUI managing agents (Claude/Codex/Gemini) across projects with cmux as one of three multiplexer backends - uniquely treats cmux as a pluggable transport rather than a hard dependency",
    "language": "Rust",
    "stars": 17,
    "categories": [
      "Multi-Agent Orchestration",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "javiermolinar/pi-cmux",
    "url": "https://github.com/javiermolinar/pi-cmux",
    "agent": "Pi",
    "description": "Extend Pi sessions with cmux notifications, sidebar status/progress, split creation, browser panes, screen reads, and zoxide-powered jumps",
    "language": "TypeScript",
    "stars": 16,
    "categories": [
      "Sidebar & Status Pills",
      "Progress Bars & Estimation",
      "Desktop Notifications",
      "Browser Automation",
      "Worktrees & Workspace Management",
      "Themes, Layouts & Config",
      "Pi"
    ]
  },
  {
    "name": "gonzaloserrano/streamdeck-cmux",
    "url": "https://github.com/gonzaloserrano/streamdeck-cmux",
    "description": "Extends status visibility beyond the screen entirely: mirror workspace state, progress bars, and notification badges onto Elgato Stream Deck hardware buttons - the only physical-hardware integration in the list",
    "language": "TypeScript",
    "stars": 14,
    "categories": [
      "Sidebar & Status Pills",
      "Progress Bars & Estimation",
      "Monitoring & Session Restore"
    ]
  },
  {
    "name": "sasha-computer/pi-cmux",
    "url": "https://github.com/sasha-computer/pi-cmux",
    "agent": "Pi",
    "description": "Maintains exactly four live pills (model, state, thinking, tokens) via a persistent socket client, and unlike joelhooks/pi-cmux's heartbeat approach, generates context-aware notification summaries using LLM calls",
    "language": "TypeScript",
    "stars": 14,
    "categories": [
      "Sidebar & Status Pills",
      "Desktop Notifications",
      "Browser Automation",
      "Pi"
    ]
  },
  {
    "name": "hummer98/cmux-team",
    "url": "https://github.com/hummer98/cmux-team",
    "agent": "Claude Code",
    "description": "Run a task-queue daemon that spawns conductor and worker sub-agents in visible cmux split panes with a TUI dashboard - differs from erk by operating entirely in-terminal with no git-worktree isolation",
    "language": "TypeScript",
    "stars": 10,
    "categories": [
      "Progress Bars & Estimation",
      "Multi-Agent Orchestration",
      "Monitoring & Session Restore",
      "Claude Code"
    ]
  },
  {
    "name": "joelhooks/pi-cmux",
    "url": "https://github.com/joelhooks/pi-cmux",
    "agent": "Pi",
    "description": "Send native macOS notifications combined with attention-cycle tab indicators and auto-generated session names; uniquely auto-names sessions from task context so notifications carry a human-readable label",
    "language": "TypeScript",
    "stars": 10,
    "categories": [
      "Sidebar & Status Pills",
      "Desktop Notifications",
      "Multi-Agent Orchestration",
      "Pi"
    ]
  },
  {
    "name": "jasonraz/cmux-browser-mcp",
    "url": "https://github.com/jasonraz/cmux-browser-mcp",
    "agent": "Claude Code",
    "description": "Expose 43 discrete MCP tools covering navigation, DOM clicking, form filling, screenshots, JS eval, and network inspection - the widest MCP tool surface of any browser plugin",
    "language": "JavaScript",
    "stars": 8,
    "categories": [
      "Browser Automation",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "darkspock/cmux-skill",
    "url": "https://github.com/darkspock/cmux-skill",
    "agent": "Multi",
    "description": "Teach agents the full cmux browser surface covering DOM interaction, JS eval, cookies, tab management, dialogs, and frames - the most starred standalone skill document for browser subcommands",
    "language": "Markdown",
    "stars": 7,
    "categories": [
      "Browser Automation",
      "Claude Code",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "yigitkonur/cmux-claude-pro",
    "url": "https://github.com/yigitkonur/cmux-claude-pro",
    "agent": "Claude Code",
    "description": "Emit formatted sidebar log entries for all sixteen lifecycle hooks - the only Claude Code plugin that attaches git branch and commit metadata to each entry, making logs navigable as a lightweight session audit trail",
    "language": "TypeScript",
    "stars": 7,
    "categories": [
      "Sidebar & Status Pills",
      "Progress Bars & Estimation",
      "Sidebar Logs & Activity Feed",
      "Desktop Notifications",
      "Claude Code"
    ]
  },
  {
    "name": "hummer98/cmux-remote",
    "url": "https://github.com/hummer98/cmux-remote",
    "description": "Self-host a PWA bridge that can read, switch, and send input to cmux surfaces over WebSocket through the cmux socket API",
    "language": "TypeScript",
    "stars": 6,
    "categories": [
      "Remote & Mobile Access"
    ]
  },
  {
    "name": "mikasalikh/cmux-wf",
    "url": "https://github.com/mikasalikh/cmux-wf",
    "agent": "Claude Code",
    "description": "Bundle a PM orchestrator script with SKILL.md that reads PRDs and distributes work to agents via the cmux socket API - the only skill pairing project management with cmux dispatch",
    "language": "Shell",
    "stars": 6,
    "categories": [
      "Multi-Agent Orchestration",
      "Claude Code"
    ]
  },
  {
    "name": "EtanHey/cmuxlayer",
    "url": "https://github.com/EtanHey/cmuxlayer",
    "agent": "Multi",
    "description": "Expose 29 MCP tools over the cmux Unix socket for sidebar updates, progress, split creation, screen reads, browser automation, and agent orchestration",
    "language": "TypeScript",
    "stars": 5,
    "categories": [
      "Sidebar & Status Pills",
      "Progress Bars & Estimation",
      "Multi-Agent Orchestration",
      "Browser Automation",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "itsmaleen/cmux-companion",
    "url": "https://github.com/itsmaleen/cmux-companion",
    "description": "Mirror cmux notifications to an iPhone via a Go bridge server over LAN WebSocket; uniquely extends notifications off the Mac entirely - no other entry targets a secondary device",
    "language": "Go / Swift",
    "stars": 5,
    "categories": [
      "Desktop Notifications",
      "Remote & Mobile Access"
    ]
  },
  {
    "name": "monzou/mo-cmux",
    "url": "https://github.com/monzou/mo-cmux",
    "agent": "Claude Code",
    "description": "Preview Markdown files in a browser split with live-reload on save and fuzzy filename matching - focused narrowly on Markdown rendering rather than general browser control",
    "language": "Shell",
    "stars": 5,
    "categories": [
      "Browser Automation",
      "Claude Code"
    ]
  },
  {
    "name": "ttalkkag/cmux-agent",
    "url": "https://github.com/ttalkkag/cmux-agent",
    "agent": "Multi",
    "description": "Broker messages between controller, orchestrator, and worker cmux tabs with JSON artifact routing via file-watching and send_text - the only plugin using SQLite as a control plane for tab coordination",
    "language": "Python",
    "stars": 5,
    "categories": [
      "Multi-Agent Orchestration",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "0xNekr/cmux-bus",
    "url": "https://github.com/0xNekr/cmux-bus",
    "agent": "Multi",
    "description": "Coordinate adjacent cmux panes through an append-only JSONL message bus with file ownership claims and escalation records, giving agents a lightweight audit trail without a daemon, MCP server, or database",
    "language": "Shell",
    "categories": [
      "Multi-Agent Orchestration",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "alaasdk/cmux-ctl",
    "url": "https://github.com/alaasdk/cmux-ctl",
    "agent": "Claude Code",
    "description": "Display a real-time TUI dashboard of all active workspaces with keyboard-driven agent launching and direct input - control-plane view complementing skills that focus on task dispatch",
    "language": "Python",
    "categories": [
      "Multi-Agent Orchestration",
      "Monitoring & Session Restore",
      "Claude Code"
    ]
  },
  {
    "name": "albertlieyingadrian/cmux-multiplexer",
    "url": "https://github.com/albertlieyingadrian/cmux-multiplexer",
    "agent": "Claude Code",
    "description": "Spawn child Claude Code workspaces from an orchestrator session, brief each one with a task, and isolate work in git worktrees so parallel research and implementation can proceed without focus stealing",
    "language": "Python",
    "categories": [
      "Multi-Agent Orchestration",
      "Worktrees & Workspace Management",
      "Claude Code"
    ]
  },
  {
    "name": "alevental/cccp",
    "url": "https://github.com/alevental/cccp",
    "agent": "Claude Code",
    "description": "Execute YAML-based deterministic pipelines with Plan-Generate-Evaluate loops, a TypeScript state machine, cmux split-pane dashboard, and MCP approval gates - enforces repeatable multi-step workflows",
    "language": "TypeScript",
    "categories": [
      "Multi-Agent Orchestration",
      "Claude Code"
    ]
  },
  {
    "name": "anhoder/homebrew-repo",
    "url": "https://github.com/anhoder/homebrew-repo",
    "description": "Distribute a cmux-nightly cask via a personal Homebrew tap",
    "language": "Ruby",
    "categories": [
      "Build & Distribution"
    ]
  },
  {
    "name": "aschreifels/cwt",
    "url": "https://github.com/aschreifels/cwt",
    "agent": "Claude Code",
    "description": "Wrap cmux workspace, split, send, read-screen, status, progress, notify, and log commands for ticket-driven worktree setup",
    "language": "Go",
    "categories": [
      "Sidebar & Status Pills",
      "Progress Bars & Estimation",
      "Desktop Notifications",
      "Worktrees & Workspace Management",
      "Claude Code"
    ]
  },
  {
    "name": "Attamusc/copilot-cmux",
    "url": "https://github.com/Attamusc/copilot-cmux",
    "agent": "Copilot",
    "description": "Bridge Copilot CLI events to the cmux sidebar via socket JSON-RPC, covering status pills, progress bars, log entries, and desktop notifications - the only dedicated Copilot sidebar plugin in the list",
    "language": "TypeScript",
    "categories": [
      "Sidebar & Status Pills",
      "Progress Bars & Estimation",
      "Sidebar Logs & Activity Feed",
      "Desktop Notifications",
      "Copilot & Amp"
    ]
  },
  {
    "name": "Attamusc/opencode-cmux",
    "url": "https://github.com/Attamusc/opencode-cmux",
    "agent": "OpenCode",
    "description": "Bridge OpenCode activity to cmux via socket or CLI with sidebar status, progress bars, logs, notifications, question prompts, and permission state",
    "language": "TypeScript",
    "categories": [
      "Sidebar & Status Pills",
      "Progress Bars & Estimation",
      "Sidebar Logs & Activity Feed",
      "Desktop Notifications",
      "OpenCode"
    ]
  },
  {
    "name": "Attamusc/pi-cmux",
    "url": "https://github.com/Attamusc/pi-cmux",
    "agent": "Pi",
    "description": "Show needs-attention banners that auto-clear after ten seconds with render throttling; unlike joelhooks' persistent indicators, alerts self-dismiss to avoid cluttering the notification center",
    "language": "TypeScript",
    "categories": [
      "Sidebar & Status Pills",
      "Progress Bars & Estimation",
      "Desktop Notifications",
      "Pi"
    ]
  },
  {
    "name": "baixianger/claude-orchestration-in-cmux",
    "url": "https://github.com/baixianger/claude-orchestration-in-cmux",
    "agent": "Claude Code",
    "description": "Coordinate parallel work via pane delegation with cmux send/read-screen through worktrees - emphasizes git-worktree isolation as the coordination boundary rather than shared workspace",
    "language": "Markdown",
    "categories": [
      "Multi-Agent Orchestration",
      "Worktrees & Workspace Management",
      "Claude Code"
    ]
  },
  {
    "name": "basedcorp99/claude-worktree-zsh",
    "url": "https://github.com/basedcorp99/claude-worktree-zsh",
    "agent": "Multi",
    "description": "Provide Zsh helpers that detect CMUX_WORKSPACE_ID, open cmux workspaces, send commands, and update cmux sidebar status/progress for multi-agent worktrees",
    "language": "Shell",
    "categories": [
      "Sidebar & Status Pills",
      "Progress Bars & Estimation",
      "Multi-Agent Orchestration",
      "Worktrees & Workspace Management",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "bhandeland/fleet",
    "url": "https://github.com/bhandeland/fleet",
    "agent": "Claude Code",
    "description": "Orchestrate multiple parallel Claude Code worktrees from a single sidebar that shows live session status, lets you spawn named agents per branch, and merges everything back in one command",
    "language": "Shell",
    "categories": [
      "Worktrees & Workspace Management",
      "Claude Code"
    ]
  },
  {
    "name": "bjacobso/pimux",
    "url": "https://github.com/bjacobso/pimux",
    "agent": "Pi",
    "description": "Manage parallel Pi agents via an Effect service with per-task workspaces, sidebar state machine, and diff review workflow - adds typed Effect-based orchestration on top of Pi's native agent model",
    "language": "TypeScript",
    "categories": [
      "Desktop Notifications",
      "Multi-Agent Orchestration",
      "Worktrees & Workspace Management",
      "Pi"
    ]
  },
  {
    "name": "block/cmux-amp",
    "url": "https://github.com/block/cmux-amp",
    "agent": "Amp",
    "description": "Keep Amp-specific cmux notification and session-restore hooks for workflows that need behavior beyond the status support now built into cmux core",
    "language": "TypeScript",
    "categories": [
      "Desktop Notifications",
      "Monitoring & Session Restore",
      "Copilot & Amp"
    ]
  },
  {
    "name": "bocktae80/cmux-pilot",
    "url": "https://github.com/bocktae80/cmux-pilot",
    "agent": "Claude Code",
    "description": "Focuses on session persistence rather than live decoration: manage workspace-to-session mappings and bulk-resume all sessions after a system restart, a recovery workflow absent from other Claude Code plugins",
    "language": "Shell",
    "categories": [
      "Sidebar & Status Pills",
      "Multi-Agent Orchestration",
      "Monitoring & Session Restore",
      "Claude Code"
    ]
  },
  {
    "name": "budah1987/cmux-script",
    "url": "https://github.com/budah1987/cmux-script",
    "agent": "Claude Code",
    "description": "Launch an interactive project picker that opens yazi, lazygit, and Claude Code in a 3-pane layout and auto-starts the appropriate dev server for the selected project",
    "language": "Shell",
    "categories": [
      "Themes, Layouts & Config",
      "Claude Code"
    ]
  },
  {
    "name": "budah1987/homebrew-tools",
    "url": "https://github.com/budah1987/homebrew-tools",
    "agent": "Claude Code",
    "description": "Distribute the cmux workspace launcher above as a Homebrew formula, resolving yazi, lazygit, and dev-tool dependencies so any Mac can install it in one command",
    "language": "Ruby",
    "categories": [
      "Themes, Layouts & Config",
      "Claude Code",
      "Build & Distribution"
    ]
  },
  {
    "name": "chsm04/cmux-tower",
    "url": "https://github.com/chsm04/cmux-tower",
    "agent": "Claude Code",
    "description": "Define TOML workspace presets with role prompts, split layouts, and single/team/manual modes, then launch repeatable Claude Code workspaces from an interactive control tower instead of ad hoc shell history",
    "language": "Shell",
    "categories": [
      "Worktrees & Workspace Management",
      "Themes, Layouts & Config",
      "Claude Code"
    ]
  },
  {
    "name": "dd7200/pomo-tui",
    "url": "https://github.com/dd7200/pomo-tui",
    "description": "Fire cmux notify on Pomodoro phase changes from a terminal TUI timer - the only standalone productivity tool using cmux notifications as its alert mechanism",
    "language": "Go",
    "categories": [
      "Desktop Notifications"
    ]
  },
  {
    "name": "dmallory42/pi-cmux",
    "url": "https://github.com/dmallory42/pi-cmux",
    "agent": "Pi",
    "description": "Launch Pi inside named cmux workspaces and expose slash commands for status pills, progress bars, logs, browser splits, and screen reads, combining workspace setup and live sidebar reporting in one small Pi package",
    "language": "TypeScript",
    "categories": [
      "Sidebar & Status Pills",
      "Progress Bars & Estimation",
      "Sidebar Logs & Activity Feed",
      "Desktop Notifications",
      "Browser Automation",
      "Worktrees & Workspace Management",
      "Themes, Layouts & Config",
      "Pi"
    ]
  },
  {
    "name": "dongsik93/crosstalk",
    "url": "https://github.com/dongsik93/crosstalk",
    "agent": "Multi",
    "description": "Fan one prompt into visible Claude, Codex, and Antigravity panes, collect deterministic agree/disagree markers, and support co-work assignments backed by temporary files instead of hidden broker state",
    "language": "Shell",
    "categories": [
      "Multi-Agent Orchestration",
      "Worktrees & Workspace Management",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "doublezz10/figure-viewer",
    "url": "https://github.com/doublezz10/figure-viewer",
    "agent": "OpenCode",
    "description": "Open scientific figures in a cmux browser pane when CMUX_SOCKET_PATH or CMUX_WORKSPACE_ID is present, with freshness timestamps and auto-refresh",
    "language": "JavaScript",
    "categories": [
      "Browser Automation"
    ]
  },
  {
    "name": "earchibald/cmux-layout",
    "url": "https://github.com/earchibald/cmux-layout",
    "description": "Inspect and apply cmux layouts through Unix socket JSON-RPC, covering workspace, pane, and surface listing for reusable topology descriptors",
    "language": "Swift",
    "categories": [
      "Themes, Layouts & Config"
    ]
  },
  {
    "name": "eduwass/cru",
    "url": "https://github.com/eduwass/cru",
    "agent": "Claude Code",
    "description": "Mirror Claude/tmux workers into cmux splits while updating cmux sidebar status, progress, and logs for team orchestration",
    "language": "TypeScript",
    "categories": [
      "Sidebar & Status Pills",
      "Progress Bars & Estimation",
      "Sidebar Logs & Activity Feed",
      "Multi-Agent Orchestration",
      "Claude Code"
    ]
  },
  {
    "name": "ensarkovankaya/cmux-mirror",
    "url": "https://github.com/ensarkovankaya/cmux-mirror",
    "description": "Mirror a remote cmux layout to a local instance over SSH with incremental sync support - observability tool focused on remote-to-local layout replication rather than agent state",
    "language": "Python",
    "categories": [
      "Monitoring & Session Restore",
      "Remote & Mobile Access"
    ]
  },
  {
    "name": "erikhazzard/cmux-remote",
    "url": "https://github.com/erikhazzard/cmux-remote",
    "description": "Self-host a remote mirror via local bridge + Cloudflare tunnel with a phone web app over WebSocket for terminal preview and workspace switching - zero-config remote access via tunnel",
    "language": "TypeScript",
    "categories": [
      "Remote & Mobile Access"
    ]
  },
  {
    "name": "eunjae-lee/cmux-worktree",
    "url": "https://github.com/eunjae-lee/cmux-worktree",
    "description": "Drive worktree creation from a declarative YAML workspace definition, supporting custom pre/post workflows, configurable split layouts, and per-pane isolated browser storage",
    "language": "TypeScript",
    "categories": [
      "Worktrees & Workspace Management",
      "Themes, Layouts & Config"
    ]
  },
  {
    "name": "EverybodyBusiness/cmux-browser-first",
    "url": "https://github.com/EverybodyBusiness/cmux-browser-first",
    "agent": "Claude Code",
    "description": "Force cmux browser tools to always be prioritized via three slash commands (/browse, /browse-check, /browse-compare) - the only plugin that elevates browser to the default tool choice in Korean",
    "categories": [
      "Browser Automation",
      "Claude Code"
    ]
  },
  {
    "name": "goddaehee/cmux-claude-skill",
    "url": "https://github.com/goddaehee/cmux-claude-skill",
    "agent": "Claude Code",
    "description": "Map all 40+ browser subcommands alongside workspace navigation and a tmux-to-cmux migration table, written in Korean - uniquely serves developers migrating existing tmux muscle memory",
    "language": "Markdown",
    "categories": [
      "Browser Automation",
      "Claude Code"
    ]
  },
  {
    "name": "gomipapa/cmux-sidecar",
    "url": "https://github.com/gomipapa/cmux-sidecar",
    "agent": "Multi",
    "description": "Install Claude Code and Codex adapters that open code-server as a cmux sidecar pane, giving agents a neighboring editor surface without bundling or silently installing editor dependencies",
    "language": "Shell",
    "categories": [
      "Browser Automation",
      "Themes, Layouts & Config",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "halindrome/cmux-tmux-mapping-for-cc",
    "url": "https://github.com/halindrome/cmux-tmux-mapping-for-cc",
    "agent": "Claude Code",
    "description": "Experimental tmux-to-cmux command mapping for Claude Code skills; upstream README marks it as unstable and not ready for dependable workflows",
    "language": "Shell",
    "categories": [
      "Multi-Agent Orchestration",
      "Claude Code"
    ]
  },
  {
    "name": "hashangit/cmux-skill",
    "url": "https://github.com/hashangit/cmux-skill",
    "agent": "Claude Code",
    "description": "Teach Claude Code cmux splits, browser refs, CMUX_SOCKET_PATH workflows, and cmux notify-based decisions for when to alert or open panes",
    "language": "Shell",
    "categories": [
      "Desktop Notifications",
      "Browser Automation",
      "Claude Code"
    ]
  },
  {
    "name": "hoonkim/cmux-skills-plugin",
    "url": "https://github.com/hoonkim/cmux-skills-plugin",
    "agent": "Claude Code",
    "description": "Enable browser automation and pane control via cmux tree, read-screen, and send, with all documentation in Korean - distinct by emphasizing pane-tree introspection commands not covered in English-language skills",
    "language": "Markdown",
    "categories": [
      "Browser Automation",
      "Claude Code"
    ]
  },
  {
    "name": "hopchouinard/cmux-plugin",
    "url": "https://github.com/hopchouinard/cmux-plugin",
    "agent": "Claude Code",
    "description": "Fire completion notifications alongside tab renaming and live progress bars; uniquely bundles three UX concerns (notify + rename + progress) in a single shell plugin rather than notifications alone",
    "language": "Shell",
    "categories": [
      "Sidebar & Status Pills",
      "Progress Bars & Estimation",
      "Desktop Notifications",
      "Browser Automation",
      "Worktrees & Workspace Management",
      "Claude Code"
    ]
  },
  {
    "name": "Islanders-Treasure0969/claude-pilot",
    "url": "https://github.com/Islanders-Treasure0969/claude-pilot",
    "agent": "Claude Code",
    "description": "Provide a browser-based dev cockpit with declarative workflow.yml gates, substep tracking, and Autopilot via cmux send - uniquely exposes a Ctrl+K command palette for manual override during automated runs",
    "language": "JavaScript",
    "categories": [
      "Multi-Agent Orchestration",
      "Browser Automation",
      "Monitoring & Session Restore",
      "Claude Code"
    ]
  },
  {
    "name": "JacianLiu/cmux-claude-session",
    "url": "https://github.com/JacianLiu/cmux-claude-session",
    "agent": "Claude Code",
    "description": "Capture and restore sessions using stable layout coordinates instead of volatile surface UUIDs with a layout-change hook for live remapping - solves the UUID-instability problem that breaks other restore tools",
    "language": "Shell",
    "categories": [
      "Monitoring & Session Restore",
      "Claude Code"
    ]
  },
  {
    "name": "jacobtellep/cmux-setup",
    "url": "https://github.com/jacobtellep/cmux-setup",
    "agent": "Claude Code",
    "description": "Replicate Conductor's IDE-style 3-pane layout - Claude agent, lazygit, and dev server - in a single bootstrap command with a dark-teal colour scheme",
    "language": "Shell",
    "categories": [
      "Themes, Layouts & Config",
      "Claude Code"
    ]
  },
  {
    "name": "jaequery/cmux-diff",
    "url": "https://github.com/jaequery/cmux-diff",
    "agent": "Claude Code",
    "description": "Show Shiki-powered syntax-highlighted diffs in a browser split with multi-file selection and AI-generated commit message suggestions - distinct from azu/cmux-hub by pairing diff viewing with commit authoring",
    "language": "TypeScript",
    "categories": [
      "Browser Automation",
      "Claude Code"
    ]
  },
  {
    "name": "jhta/cmux-skill",
    "url": "https://github.com/jhta/cmux-skill",
    "agent": "Claude Code",
    "description": "Teach Claude Code Neovim-centric editing patterns: open files at the right line, render delta diffs, and run tests in adjacent panes without leaving the agent window",
    "language": "Shell",
    "categories": [
      "Themes, Layouts & Config",
      "Claude Code"
    ]
  },
  {
    "name": "Joehoel/opencode-cmux",
    "url": "https://github.com/Joehoel/opencode-cmux",
    "agent": "OpenCode",
    "description": "Report OpenCode status, progress, logs, notifications, and project-management context to cmux, with Azure DevOps and Jira signals as optional sidebar metadata",
    "language": "Shell",
    "categories": [
      "Sidebar & Status Pills",
      "Progress Bars & Estimation",
      "Sidebar Logs & Activity Feed",
      "Desktop Notifications",
      "OpenCode"
    ]
  },
  {
    "name": "KyleJamesWalker/cc-cmux-plugin",
    "url": "https://github.com/KyleJamesWalker/cc-cmux-plugin",
    "agent": "Claude Code",
    "description": "Route notifications through cmux notify with auto-granted CLI permissions pre-configured; distinguishes itself by solving the permission-prompt problem so notifications fire silently on first run",
    "categories": [
      "Sidebar & Status Pills",
      "Desktop Notifications",
      "Themes, Layouts & Config",
      "Claude Code"
    ]
  },
  {
    "name": "KyubumShin/cmux-skills",
    "url": "https://github.com/KyubumShin/cmux-skills",
    "agent": "Claude Code",
    "description": "Provide three skills: /cmux-control for remote session control with 8-state detection, /cmux-get for context import, and /cmux-md-preview for interactive Markdown checklists - granular per-feature skill separation",
    "language": "JavaScript",
    "categories": [
      "Multi-Agent Orchestration",
      "Browser Automation",
      "Monitoring & Session Restore",
      "Claude Code"
    ]
  },
  {
    "name": "LattyCat/cmux-workspace",
    "url": "https://github.com/LattyCat/cmux-workspace",
    "agent": "Multi",
    "description": "Create a Japanese 4-pane layout: yazi + glow/watchexec Markdown preview + lazygit + AI terminal with symlinks to the cmux command palette - opinionated development cockpit for Japanese-language workflows",
    "language": "Shell",
    "categories": [
      "Worktrees & Workspace Management",
      "Themes, Layouts & Config",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "lawrencecchen/cmux-proxy",
    "url": "https://github.com/lawrencecchen/cmux-proxy",
    "description": "Route HTTP/WebSocket/TCP traffic through a header-based reverse proxy with per-workspace network isolation",
    "language": "Rust",
    "categories": [
      "Remote & Mobile Access"
    ]
  },
  {
    "name": "Lumiwealth/cmux-agent-recovery",
    "url": "https://github.com/Lumiwealth/cmux-agent-recovery",
    "agent": "Multi",
    "description": "Record Claude Code and Codex resume metadata on each turn, then recover one restored cmux workspace at a time after crashes or updates without bulk-starting stale sessions blindly",
    "language": "Python",
    "categories": [
      "Monitoring & Session Restore",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "madlouse/homebrew-ghostty",
    "url": "https://github.com/madlouse/homebrew-ghostty",
    "description": "Install a full AI stack (cmux + Ghostty + Zed + Starship + JetBrainsMono) via a single Homebrew formula with idempotent re-runs and dry-run mode - one-command developer environment bootstrap",
    "language": "Ruby",
    "categories": [
      "Build & Distribution"
    ]
  },
  {
    "name": "manaflow-ai/chromium",
    "url": "https://github.com/manaflow-ai/chromium",
    "description": "Build a Chromium content shell for cmux's browser engine with prebuilt framework downloads for plugin developers",
    "language": "Obj-C++",
    "categories": [
      "Build & Distribution"
    ]
  },
  {
    "name": "manaflow-ai/cmux-skills",
    "url": "https://github.com/manaflow-ai/cmux-skills",
    "agent": "Multi",
    "description": "Provide installable cmux skills for any Agent Skills-compatible runtime, covering CLI control, settings, browser automation, artifacts, workspace refs, and customization from one maintained public source",
    "language": "Python",
    "categories": [
      "Multi-Agent Orchestration",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "manaflow-ai/homebrew-cmux",
    "url": "https://github.com/manaflow-ai/homebrew-cmux",
    "description": "Provide the official Homebrew tap for cmux with stable and nightly casks maintained by Manaflow",
    "language": "Ruby",
    "categories": [
      "Build & Distribution"
    ]
  },
  {
    "name": "mangledmonkey/cmux-skills",
    "url": "https://github.com/mangledmonkey/cmux-skills",
    "agent": "Claude Code",
    "description": "Teach Claude Code browser automation across four auto-syncing skill files covering form filling, screenshots, and debug window capture - structured as a multi-file skill suite rather than a single monolithic document",
    "language": "Shell",
    "categories": [
      "Browser Automation",
      "Claude Code"
    ]
  },
  {
    "name": "mangledmonkey/devmux",
    "url": "https://github.com/mangledmonkey/devmux",
    "agent": "Claude Code",
    "description": "Implement a master-worker pattern using worktrees, cmux workspaces, and Agent Teams (lead+tester+reviewer+security) with deterministic port allocation - uniquely assigns fixed ports per agent role",
    "language": "Shell",
    "categories": [
      "Multi-Agent Orchestration",
      "Worktrees & Workspace Management",
      "Claude Code"
    ]
  },
  {
    "name": "Marmalade118/gsd-wmux",
    "url": "https://github.com/Marmalade118/gsd-wmux",
    "agent": "Pi",
    "description": "Drop-in replacement for GSD/Pi's @gsd/cmux module adding WezTerm as a second multiplexer backend with OSC 1337 user variables and Windows toast notifications - the only Pi plugin supporting dual multiplexer targets",
    "language": "TypeScript",
    "categories": [
      "Sidebar & Status Pills",
      "Progress Bars & Estimation",
      "Desktop Notifications",
      "Themes, Layouts & Config",
      "Pi"
    ]
  },
  {
    "name": "mastertyko/pi-cmux-preview",
    "url": "https://github.com/mastertyko/pi-cmux-preview",
    "agent": "Pi",
    "description": "Render assistant Markdown responses as styled HTML in a cmux browser pane with inline terminal screenshots and file previews - turns the browser pane into a rich conversation renderer rather than a web browser",
    "language": "TypeScript",
    "categories": [
      "Browser Automation",
      "Pi"
    ]
  },
  {
    "name": "mateusduraes/ramo",
    "url": "https://github.com/mateusduraes/ramo",
    "description": "Create worktrees from ramo.json, run setup commands, copy env files, and open the result in cmux workspaces and splits",
    "language": "Go",
    "categories": [
      "Worktrees & Workspace Management"
    ]
  },
  {
    "name": "meengi07/cmux-agent-observer-skill",
    "url": "https://github.com/meengi07/cmux-agent-observer-skill",
    "agent": "Multi",
    "description": "Track worker sub-agent progress from the cmux sidebar using structured handoff notes written to a dedicated directory - file-based coordination approach contrasts with socket or daemon-driven monitors",
    "language": "Shell",
    "categories": [
      "Multi-Agent Orchestration",
      "Monitoring & Session Restore",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "Michael-Z-Freeman/antigravity-cmux-notify",
    "url": "https://github.com/Michael-Z-Freeman/antigravity-cmux-notify",
    "agent": "Antigravity",
    "description": "Wire Google Antigravity CLI hooks to cmux notifications through Antigravity's hooks.json contract, with stdout-safe JSON handling so the notification hook does not invalidate the agent runtime",
    "language": "Shell",
    "categories": [
      "Desktop Notifications",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "mikecfisher/cmux-skill",
    "url": "https://github.com/mikecfisher/cmux-skill",
    "agent": "Claude Code",
    "description": "Cover browser automation as part of a broad CLI taxonomy that uniquely documents capture-pane internals and CMUX_SOCKET_PASSWORD authentication - more reference than tutorial",
    "language": "Markdown",
    "categories": [
      "Browser Automation",
      "Claude Code"
    ]
  },
  {
    "name": "Minoo7/cmux-hooks",
    "url": "https://github.com/Minoo7/cmux-hooks",
    "agent": "Multi",
    "description": "Fan out cmux-aware hooks to SSH hosts, Hermes, and omp/Pi, then relay agent activity back as local notifications and sidebar badges through a stdlib helper rather than per-agent hand-written scripts",
    "language": "Shell",
    "categories": [
      "Sidebar & Status Pills",
      "Desktop Notifications",
      "Monitoring & Session Restore",
      "Remote & Mobile Access",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "miraoto/cmux-cheatsheet",
    "url": "https://github.com/miraoto/cmux-cheatsheet",
    "description": "Provide c-help CLI: offline searchable cheatsheet for all cmux keyboard shortcuts, CLI commands, sidebar APIs, browser automation, and env vars in English and Japanese",
    "language": "Shell",
    "categories": [
      "Themes, Layouts & Config"
    ]
  },
  {
    "name": "Mirksen/cmux-toolkit",
    "url": "https://github.com/Mirksen/cmux-toolkit",
    "agent": "Claude Code",
    "description": "Skips status pills in favour of IDE ergonomics: auto-open edited files in a Vim subpane and toggle a broot file-browser sidebar, turning cmux into a lightweight editor environment",
    "language": "Shell",
    "categories": [
      "Browser Automation",
      "Themes, Layouts & Config",
      "Claude Code"
    ]
  },
  {
    "name": "morrisclay/ws",
    "url": "https://github.com/morrisclay/ws",
    "agent": "Claude Code",
    "description": "Open or focus workspaces with ws , scaffold with CLAUDE.md and permissions via ws init, and integrate Flox envs plus 1Password CLI secrets - combines workspace management with secrets injection",
    "language": "Shell",
    "categories": [
      "Worktrees & Workspace Management",
      "Themes, Layouts & Config",
      "Claude Code"
    ]
  },
  {
    "name": "mspiegel31/opencode-cmux",
    "url": "https://github.com/mspiegel31/opencode-cmux",
    "agent": "OpenCode",
    "description": "Push desktop notifications on idle or error alongside subagent viewer panes and browser tools; distinguishes itself by pairing notification events with visible subagent viewer panes in the same plugin",
    "language": "TypeScript",
    "categories": [
      "Desktop Notifications",
      "Browser Automation",
      "OpenCode"
    ]
  },
  {
    "name": "multiagentcognition/cmux-agent-mcp",
    "url": "https://github.com/multiagentcognition/cmux-agent-mcp",
    "agent": "Multi",
    "description": "Expose 81 MCP tools spanning agent spawning, sidebar metadata, notifications, browser automation, and session recovery - the largest MCP surface area of any plugin here, unlike EtanHey/cmuxlayer's focused 22-tool set",
    "language": "TypeScript",
    "categories": [
      "Sidebar & Status Pills",
      "Progress Bars & Estimation",
      "Sidebar Logs & Activity Feed",
      "Multi-Agent Orchestration",
      "Browser Automation",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "n-filatov/cmux-workspace",
    "url": "https://github.com/n-filatov/cmux-workspace",
    "agent": "Multi",
    "description": "Store per-repo setup commands in .cmux-workspace.json and spawn cmux workspaces from that config, so project bootstrap, worktree creation, and workspace launch remain one repeatable command",
    "language": "TypeScript",
    "categories": [
      "Worktrees & Workspace Management",
      "Themes, Layouts & Config",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "NewTurn2017/cmux-remote",
    "url": "https://github.com/NewTurn2017/cmux-remote",
    "description": "Control cmux from an iPhone over Tailscale with a SwiftUI client and Swift relay daemon, keeping terminal mirroring, key input, and workspace operations inside the user's private tailnet",
    "language": "Swift",
    "categories": [
      "Remote & Mobile Access",
      "Multi-Agent / Agent-Agnostic"
    ],
    "agent": "Multi"
  },
  {
    "name": "niaeee/cmux_skill",
    "url": "https://github.com/niaeee/cmux_skill",
    "agent": "Claude Code",
    "description": "Orchestrate 124 domain specialists via an 802-line skill file with 18 hooks, 28 scripts, and surface watcher detecting IDLE/ERROR/STALL states - the most granular Korean-language sidebar state machine for Claude Code",
    "categories": [
      "Sidebar & Status Pills",
      "Multi-Agent Orchestration",
      "Monitoring & Session Restore",
      "Claude Code"
    ]
  },
  {
    "name": "ogallotti/cmux-tmux-shim",
    "url": "https://github.com/ogallotti/cmux-tmux-shim",
    "agent": "Claude Code",
    "description": "Translate tmux commands to cmux equivalents, enabling --teammate-mode tmux (Agent Teams) inside cmux by mapping pane IDs to surface IDs - solves the tmux-compatibility gap for agent team mode",
    "language": "Shell",
    "categories": [
      "Multi-Agent Orchestration",
      "Claude Code"
    ]
  },
  {
    "name": "owizdom/context-brdige-for-cmux",
    "url": "https://github.com/owizdom/context-brdige-for-cmux",
    "agent": "Multi",
    "description": "Poll panes from any agent, extract structured context, persist snapshots to SQLite, and auto-inject compressed handoff briefs into new sessions - persistence layer differentiates it from in-memory restore tools",
    "language": "Go",
    "categories": [
      "Multi-Agent Orchestration",
      "Monitoring & Session Restore",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "pallidev/cmux-relay",
    "url": "https://github.com/pallidev/cmux-relay",
    "description": "Stream cmux terminal sessions to any device with a TypeScript relay agent and optional ACP chat integration, emphasizing phone-friendly monitoring for Claude Code, Codex, and Gemini panes",
    "language": "TypeScript",
    "categories": [
      "Remote & Mobile Access",
      "Multi-Agent / Agent-Agnostic"
    ],
    "agent": "Multi"
  },
  {
    "name": "rappdw/zen-term",
    "url": "https://github.com/rappdw/zen-term",
    "agent": "Claude Code",
    "description": "Forward OSC 777 rings from a remote DGX Spark to the local MacBook running cmux via Mosh; uniquely solves the remote-GPU-to-local-desktop notification gap - no other entry covers cross-host forwarding",
    "language": "Shell",
    "categories": [
      "Desktop Notifications",
      "Remote & Mobile Access",
      "Themes, Layouts & Config",
      "Claude Code"
    ]
  },
  {
    "name": "richardhowes/cmux-jump",
    "url": "https://github.com/richardhowes/cmux-jump",
    "description": "Resolve partial directory names via zoxide frecency, check cmux workspaces with 4-tier fuzzy matching, and switch or create with j - the only zoxide-integrated workspace switcher with 45 tests",
    "language": "Shell",
    "categories": [
      "Worktrees & Workspace Management",
      "Themes, Layouts & Config"
    ]
  },
  {
    "name": "richardhowes/cmux-mobile",
    "url": "https://github.com/richardhowes/cmux-mobile",
    "description": "Provide an iOS companion app (React Native/Expo) over Tailscale with full workspace listing, ANSI terminal rendering, keyboard shortcuts, and APNs push notifications - the most feature-complete mobile client",
    "language": "TypeScript",
    "categories": [
      "Desktop Notifications",
      "Remote & Mobile Access"
    ]
  },
  {
    "name": "Ridgeio/swarm",
    "url": "https://github.com/Ridgeio/swarm",
    "agent": "Multi",
    "description": "Coordinate Claude, Codex, and A2A agents with cmux surface IDs, send/read/spawn/move APIs, and persistent swarm state",
    "language": "TypeScript",
    "categories": [
      "Multi-Agent Orchestration",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "flotilla-org/flotilla",
    "url": "https://github.com/flotilla-org/flotilla",
    "agent": "Multi",
    "description": "Correlate agents, branches, and PRs through a development fleet dashboard with cmux as one supported multiplexer provider",
    "language": "Rust",
    "categories": [
      "Multi-Agent Orchestration",
      "Worktrees & Workspace Management",
      "Monitoring & Session Restore",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "RyoHirota68/cmux-pencil-preview",
    "url": "https://github.com/RyoHirota68/cmux-pencil-preview",
    "agent": "Claude Code",
    "description": "Auto-export Pencil design files to PDF and hot-reload them in the browser pane on each save - purpose-built for design iteration loops, not general web content",
    "language": "Shell",
    "categories": [
      "Browser Automation",
      "Claude Code"
    ]
  },
  {
    "name": "RyoHirota68/difit-cmux",
    "url": "https://github.com/RyoHirota68/difit-cmux",
    "agent": "Claude Code",
    "description": "Auto-reload the difit web diff viewer in a cmux browser pane triggered by Claude Code rules after file changes with per-workspace port isolation - purpose-built for continuous visual diff monitoring",
    "language": "Shell",
    "categories": [
      "Browser Automation",
      "Claude Code"
    ]
  },
  {
    "name": "sanurb/pi-cmux",
    "url": "https://github.com/sanurb/pi-cmux",
    "agent": "Pi",
    "description": "Focuses specifically on safe command execution: adds an explicit allowlist for workspace tools alongside focus-aware debounced macOS notifications, a security layer absent from other Pi plugins",
    "language": "TypeScript",
    "categories": [
      "Sidebar & Status Pills",
      "Desktop Notifications",
      "Pi"
    ]
  },
  {
    "name": "sanurb/pi-cmux-browser",
    "url": "https://github.com/sanurb/pi-cmux-browser",
    "agent": "Pi",
    "description": "Provide Pi with typed browser automation actions (click, fill, screenshot, snapshot) plus a dedicated spawnable web-dev subagent - unique in offering a purpose-built subagent for frontend development tasks",
    "language": "TypeScript",
    "categories": [
      "Browser Automation",
      "Pi"
    ]
  },
  {
    "name": "sanurb/pi-cmux-workflows",
    "url": "https://github.com/sanurb/pi-cmux-workflows",
    "agent": "Pi",
    "description": "Display ringi-powered code reviews in cmux browser panes alongside split-pane and agent handoff slash commands - the only Pi plugin integrating a structured review workflow into the browser pane",
    "language": "TypeScript",
    "categories": [
      "Multi-Agent Orchestration",
      "Browser Automation",
      "Pi"
    ]
  },
  {
    "name": "sdgranger/will-public-claude",
    "url": "https://github.com/sdgranger/will-public-claude",
    "agent": "Claude Code",
    "description": "Bundle cmux browser, pane, status, progress, log, and notify skills with a broader Claude Code skill marketplace package",
    "language": "Shell",
    "categories": [
      "Sidebar & Status Pills",
      "Progress Bars & Estimation",
      "Sidebar Logs & Activity Feed",
      "Multi-Agent Orchestration",
      "Browser Automation",
      "Claude Code"
    ]
  },
  {
    "name": "Seungwoo321/cmux-setup",
    "url": "https://github.com/Seungwoo321/cmux-setup",
    "description": "Register projects and presets, then launch them as cmux workspaces and splits through a Korean-language project registry",
    "language": "TypeScript",
    "categories": [
      "Worktrees & Workspace Management",
      "Themes, Layouts & Config"
    ]
  },
  {
    "name": "simonjohansson/pi-cmux",
    "url": "https://github.com/simonjohansson/pi-cmux",
    "agent": "Pi",
    "description": "Log Pi tool executions to the sidebar feed while also exposing a single passthrough cmux_cli tool that lets Pi issue any cmux command directly, making the agent itself a first-class log author",
    "language": "TypeScript",
    "categories": [
      "Sidebar & Status Pills",
      "Sidebar Logs & Activity Feed",
      "Pi"
    ]
  },
  {
    "name": "Stealinglight/cmux-claude-code-skill",
    "url": "https://github.com/Stealinglight/cmux-claude-code-skill",
    "agent": "Claude Code",
    "description": "Document browser, CLI, and shortcuts references with concrete Python socket API examples for WebKit automation - the only skill that bridges the cmux Python socket API into browser control",
    "language": "Shell",
    "categories": [
      "Browser Automation",
      "Worktrees & Workspace Management",
      "Claude Code"
    ]
  },
  {
    "name": "stegmannb/pi-agent-cmux",
    "url": "https://github.com/stegmannb/pi-agent-cmux",
    "agent": "Pi",
    "description": "Track Pi run summaries and push completion status into cmux notifications and sidebar pills, pairing automatic run-end reporting with passive skills that let Pi update status during builds, tests, and deploys",
    "language": "TypeScript",
    "categories": [
      "Sidebar & Status Pills",
      "Desktop Notifications",
      "Pi"
    ]
  },
  {
    "name": "stevenocchipinti/raycast-cmux",
    "url": "https://github.com/stevenocchipinti/raycast-cmux",
    "description": "Search, focus, and manage cmux workspaces and panes directly from Raycast with keyboard-driven commands, eliminating the need to touch the mouse or switch apps",
    "language": "TypeScript",
    "categories": [
      "Worktrees & Workspace Management",
      "Themes, Layouts & Config"
    ]
  },
  {
    "name": "storelayer/pi-cmux-browser",
    "url": "https://github.com/storelayer/pi-cmux-browser",
    "agent": "Pi",
    "description": "Equip Pi with dual browser modes: cmux in-app WebKit for visual debugging and Playwright for headless CI workflows - the only Pi plugin that lets the agent switch between visual and headless modes per task",
    "language": "JavaScript",
    "categories": [
      "Browser Automation",
      "Pi"
    ]
  },
  {
    "name": "STRML/cmux-restore",
    "url": "https://github.com/STRML/cmux-restore",
    "agent": "Claude Code",
    "description": "Map each Claude Code session ID to its surface UUID via a SessionStart hook, then resume exact sessions after cmux restarts - hook-driven approach avoids polling and survives rapid restarts",
    "language": "Shell",
    "categories": [
      "Monitoring & Session Restore",
      "Claude Code"
    ]
  },
  {
    "name": "tadashi-aikawa/copilot-plugin-notify",
    "url": "https://github.com/tadashi-aikawa/copilot-plugin-notify",
    "agent": "Copilot",
    "description": "Emit OSC 777 notifications for tool-use approvals and agent-stop alerts so cmux-compatible terminals can surface Copilot activity",
    "language": "Shell",
    "categories": [
      "Desktop Notifications",
      "Copilot & Amp"
    ]
  },
  {
    "name": "taichiiwamoto-s/cmux-context",
    "url": "https://github.com/taichiiwamoto-s/cmux-context",
    "agent": "Claude Code",
    "description": "Specializes in context-window awareness unlike general status plugins - visualize fill percentage, line counts, and rate limits as color-coded progress bars across all open workspaces simultaneously",
    "language": "Shell",
    "categories": [
      "Sidebar & Status Pills",
      "Progress Bars & Estimation",
      "Monitoring & Session Restore",
      "Claude Code"
    ]
  },
  {
    "name": "take0x/cmux-skills",
    "url": "https://github.com/take0x/cmux-skills",
    "agent": "Claude Code",
    "description": "Offer two skills: self-referential cmux docs lookup (live cmux -h + scraped cmux.com) and /pane reader for other terminals - the only skill that dynamically scrapes upstream documentation at runtime",
    "language": "Shell",
    "categories": [
      "Monitoring & Session Restore",
      "Claude Code"
    ]
  },
  {
    "name": "tasuku43/kra",
    "url": "https://github.com/tasuku43/kra",
    "description": "Create or reuse cmux workspaces for tickets and worktrees, keeping task state aligned with visible cmux sessions",
    "language": "Go",
    "categories": [
      "Worktrees & Workspace Management"
    ]
  },
  {
    "name": "Th3Sp3ct3R/cmux-claude-agents",
    "url": "https://github.com/Th3Sp3ct3R/cmux-claude-agents",
    "agent": "Claude Code",
    "description": "Intercept Agent tool calls via a PreToolUse hook and redirect them to visible cmux split panes - hook-based approach means zero changes to the agent's own prompts or skills",
    "language": "Shell",
    "categories": [
      "Desktop Notifications",
      "Multi-Agent Orchestration",
      "Claude Code"
    ]
  },
  {
    "name": "theodaguier/wt",
    "url": "https://github.com/theodaguier/wt",
    "agent": "Claude Code",
    "description": "Create worktrees from GitHub and Linear issues: wt gh fetches the title, creates a branch, and opens a cmux tab - fzf picker for selecting from open issues",
    "language": "Shell",
    "categories": [
      "Worktrees & Workspace Management",
      "Claude Code"
    ]
  },
  {
    "name": "TimoKruth/cmux-t3code",
    "url": "https://github.com/TimoKruth/cmux-t3code",
    "agent": "Multi",
    "description": "Build a custom cmux-t3code app from a cmux submodule, embedding t3code sidecars into native cmux panels for AI coding workflows",
    "categories": [
      "Multi-Agent Orchestration",
      "Browser Automation",
      "Worktrees & Workspace Management",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "tslateman/cmux-claude-code",
    "url": "https://github.com/tslateman/cmux-claude-code",
    "agent": "Claude Code",
    "description": "Adds emoji-labeled tool names to status pills and uses a logarithmic progress curve that accounts for diminishing returns, unlike linear bars in other Shell-based Claude Code plugins",
    "language": "Shell",
    "categories": [
      "Sidebar & Status Pills",
      "Progress Bars & Estimation",
      "Desktop Notifications",
      "Claude Code"
    ]
  },
  {
    "name": "tully-8888/opencode-cmux-notify-plugin",
    "url": "https://github.com/tully-8888/opencode-cmux-notify-plugin",
    "agent": "OpenCode",
    "description": "Focuses on subagent lifecycle tracking alongside desktop notifications for questions, permissions, and errors - unlike Attamusc/opencode-cmux, does not throttle and targets completeness over performance",
    "language": "Shell",
    "categories": [
      "Sidebar & Status Pills",
      "Desktop Notifications",
      "OpenCode"
    ]
  },
  {
    "name": "umitaltintas/cmux-agent-toolkit",
    "url": "https://github.com/umitaltintas/cmux-agent-toolkit",
    "agent": "Claude Code",
    "description": "Teach fan-out execution with spawn, then synchronize via wait-for/wait-for --signal signals and explicit pane topology management - unique focus on barrier-style synchronization primitives",
    "language": "Markdown",
    "categories": [
      "Multi-Agent Orchestration",
      "Claude Code"
    ]
  },
  {
    "name": "wangyuxinwhy/agent-skills",
    "url": "https://github.com/wangyuxinwhy/agent-skills",
    "agent": "Multi",
    "description": "Deliver framework-agnostic skills symlinked into Claude Code, Codex, Coco/Trae, or OpenCode with cmux orchestration and Feishu/Lark CLI integration - the only skill set targeting five agent runtimes",
    "categories": [
      "Multi-Agent Orchestration",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "webkaz/cmux-intel-builds",
    "url": "https://github.com/webkaz/cmux-intel-builds",
    "description": "Automate Intel Mac x86_64 builds by polling upstream releases every 6 hours and publishing unsigned DMGs",
    "categories": [
      "Build & Distribution"
    ]
  },
  {
    "name": "wwaIII/proj",
    "url": "https://github.com/wwaIII/proj",
    "agent": "Claude Code",
    "description": "Launch named local projects as cmux workspaces from a Rust TUI and mark Claude Code sessions with activity badges",
    "language": "Rust",
    "categories": [
      "Themes, Layouts & Config",
      "Claude Code"
    ]
  },
  {
    "name": "ygrec-app/offload-task-skill",
    "url": "https://github.com/ygrec-app/offload-task-skill",
    "agent": "Claude Code",
    "description": "Offload a single task to a dedicated split pane with an autonomous worker, preserving main session context and token budget - minimal single-task delegation rather than full grid orchestration",
    "language": "Markdown",
    "categories": [
      "Multi-Agent Orchestration",
      "Claude Code"
    ]
  },
  {
    "name": "ygrec-app/supreme-leader-skill",
    "url": "https://github.com/ygrec-app/supreme-leader-skill",
    "agent": "Claude Code",
    "description": "Plan subtasks, spawn a 2-8 worker grid, monitor via read-screen polling, review deliverables, and dispatch fix iterations - covers the full orchestrator loop in a single skill",
    "language": "Markdown",
    "categories": [
      "Multi-Agent Orchestration",
      "Claude Code"
    ]
  },
  {
    "name": "feritzcan2/termloop",
    "url": "https://github.com/feritzcan2/termloop",
    "agent": "Multi",
    "description": "Ship a cmux-derived distribution and Homebrew fork for worktree agents, MCP handoff, and mobile monitoring workflows",
    "language": "Swift",
    "stars": 29,
    "categories": [
      "Build & Distribution",
      "Multi-Agent Orchestration",
      "Worktrees & Workspace Management",
      "Remote & Mobile Access",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "sanghun0724/cmux-claude-skills",
    "url": "https://github.com/sanghun0724/cmux-claude-skills",
    "agent": "Claude Code",
    "description": "Provide Claude Code skills for cmux layout automation, workspace snapshots, session restore, and Markdown preview workflows",
    "language": "Python",
    "stars": 28,
    "categories": [
      "Browser Automation",
      "Monitoring & Session Restore",
      "Themes, Layouts & Config",
      "Claude Code"
    ]
  },
  {
    "name": "pawel-cell/cmux-ai-agents-bundle",
    "url": "https://github.com/pawel-cell/cmux-ai-agents-bundle",
    "agent": "Multi",
    "description": "Bundle skills, hooks, recipes, and prompts for orchestrating AI agents through cmux socket, browser, notification, and workspace workflows",
    "language": "Shell / Python",
    "stars": 20,
    "categories": [
      "Multi-Agent Orchestration",
      "Browser Automation",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "ericblue/cmux-session-manager",
    "url": "https://github.com/ericblue/cmux-session-manager",
    "agent": "Claude Code",
    "description": "Snapshot and restore cmux workspaces with Claude Code session resumption, including saved pane state and controlled relaunch flows",
    "language": "Python",
    "stars": 12,
    "categories": [
      "Monitoring & Session Restore",
      "Claude Code"
    ]
  },
  {
    "name": "freestyle-sh/rigkit",
    "url": "https://github.com/freestyle-sh/rigkit",
    "agent": "Multi",
    "description": "Expose cmux as a local provider for RigKit/Freestyle development flows through provider-cmux and fdev-cmux packages",
    "language": "TypeScript",
    "stars": 7,
    "categories": [
      "Multi-Agent Orchestration",
      "Worktrees & Workspace Management",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "ph3on1x/claude-cmux-skill",
    "url": "https://github.com/ph3on1x/claude-cmux-skill",
    "agent": "Claude Code",
    "description": "Teach Claude Code to spawn cmux panes, monitor agents, automate browser surfaces, update sidebar metadata, and send notifications from one plugin",
    "language": "Markdown",
    "stars": 7,
    "categories": [
      "Sidebar & Status Pills",
      "Multi-Agent Orchestration",
      "Browser Automation",
      "Claude Code"
    ]
  },
  {
    "name": "sinozu/cmux-git-diff",
    "url": "https://github.com/sinozu/cmux-git-diff",
    "description": "Open a live git diff viewer in a cmux browser pane with localhost-first WebSocket updates and automatic refresh as files change",
    "language": "Go",
    "stars": 5,
    "categories": [
      "Browser Automation"
    ]
  },
  {
    "name": "jiahao-shao1/cmux-skill",
    "url": "https://github.com/jiahao-shao1/cmux-skill",
    "agent": "Claude Code",
    "description": "Provide Claude Code skill commands for cmux splits, CMUX_SOCKET_PATH workflows, browser automation, Markdown preview, progress, and notifications",
    "language": "Markdown",
    "stars": 5,
    "categories": [
      "Sidebar & Status Pills",
      "Progress Bars & Estimation",
      "Browser Automation",
      "Claude Code"
    ]
  },
  {
    "name": "devnazim/pi-cmux",
    "url": "https://github.com/devnazim/pi-cmux",
    "agent": "Pi",
    "description": "Publish a Pi package for cmux status and notification integration through npm as @devnazim/pi-cmux",
    "language": "TypeScript",
    "categories": [
      "Sidebar & Status Pills",
      "Desktop Notifications",
      "Pi"
    ]
  },
  {
    "name": "Catdaemon/pi-extensions",
    "url": "https://github.com/Catdaemon/pi-extensions",
    "agent": "Pi",
    "description": "Ship Pi extension packages including @catdaemon/pi-cmux for cmux status and notification workflows",
    "language": "TypeScript",
    "stars": 3,
    "categories": [
      "Sidebar & Status Pills",
      "Desktop Notifications",
      "Pi"
    ]
  },
  {
    "name": "flyflor/cmux-codex-worktree",
    "url": "https://github.com/flyflor/cmux-codex-worktree",
    "agent": "Codex",
    "description": "Launch visible child Codex TUI panes in cmux across isolated git worktree lanes for parallel implementation and review",
    "language": "Shell",
    "stars": 3,
    "categories": [
      "Multi-Agent Orchestration",
      "Worktrees & Workspace Management"
    ]
  },
  {
    "name": "tanabee/cmux.vim",
    "url": "https://github.com/tanabee/cmux.vim",
    "agent": "Multi",
    "description": "Let Vim send file references and selected line ranges into AI CLI sessions running inside cmux panes",
    "language": "Vim Script",
    "stars": 3,
    "categories": [
      "Browser Automation",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "alpeshvas/cmuxinator",
    "url": "https://github.com/alpeshvas/cmuxinator",
    "agent": "Multi",
    "description": "Launch cmux workspaces, panes, surfaces, and browser views from tmuxinator-style YAML project definitions",
    "language": "Rust",
    "stars": 2,
    "categories": [
      "Worktrees & Workspace Management",
      "Themes, Layouts & Config",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "sttts/skills",
    "url": "https://github.com/sttts/skills",
    "agent": "Multi",
    "description": "Include a Claude/Codex cmux skill that launches panes, sends prompts, reads screens, focuses panes, and manages worktrees",
    "language": "Shell",
    "stars": 2,
    "categories": [
      "Multi-Agent Orchestration",
      "Worktrees & Workspace Management",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "yigitkonur/cmux-codex",
    "url": "https://github.com/yigitkonur/cmux-codex",
    "agent": "Codex",
    "description": "Publish codex-cmux hooks for Codex status, progress, notifications, logs, and SSH socket forwarding through cmux socket or CLI integration",
    "language": "TypeScript",
    "stars": 1,
    "categories": [
      "Sidebar & Status Pills",
      "Progress Bars & Estimation",
      "Sidebar Logs & Activity Feed",
      "Desktop Notifications"
    ]
  },
  {
    "name": "mimen/claude-sessions",
    "url": "https://github.com/mimen/claude-sessions",
    "agent": "Claude Code",
    "description": "Browse and resume Claude Code sessions from a TUI, opening restored sessions into fresh cmux workspaces when requested",
    "language": "TypeScript",
    "categories": [
      "Monitoring & Session Restore",
      "Claude Code"
    ]
  },
  {
    "name": "tanaka-yui/yui-cc-plugins",
    "url": "https://github.com/tanaka-yui/yui-cc-plugins",
    "agent": "Multi",
    "description": "Ship a cmux plugin suite for remote bridging, team dispatch, usage tracking, and Claude/Codex workflows inside cmux sessions",
    "language": "TypeScript",
    "stars": 2,
    "categories": [
      "Multi-Agent Orchestration",
      "Worktrees & Workspace Management",
      "Remote & Mobile Access",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "talldan/cmux-opencode-agent-comm",
    "url": "https://github.com/talldan/cmux-opencode-agent-comm",
    "agent": "OpenCode",
    "description": "Enable OpenCode agents to communicate across cmux workspaces by sending messages and reading peer surfaces",
    "language": "TypeScript",
    "categories": [
      "Multi-Agent Orchestration",
      "OpenCode"
    ]
  },
  {
    "name": "LuisUrrutia/opencode-cmux",
    "url": "https://github.com/LuisUrrutia/opencode-cmux",
    "agent": "OpenCode",
    "description": "Publish an OpenCode plugin for project and activity feedback in cmux, distributed as @luisurrutia/opencode-cmux",
    "language": "TypeScript",
    "categories": [
      "Sidebar & Status Pills",
      "Desktop Notifications",
      "OpenCode"
    ]
  }
] as const satisfies readonly AwesomeCmuxProject[];
