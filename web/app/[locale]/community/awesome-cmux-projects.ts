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
export const awesomeCmuxProjectRows = 362;

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
  "Multi-Agent / Agent-Agnostic"
] as const;

export const awesomeCmuxProjects = [
  {
    "name": "yigitkonur/cmux-claude-pro",
    "url": "https://github.com/yigitkonur/cmux-claude-pro",
    "agent": "Claude Code",
    "description": "Cover the widest lifecycle surface of any Claude Code plugin: wire sixteen hooks for real-time status pills, adaptive progress bars, formatted log entries, git branch metadata, and subagent tracking simultaneously",
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
    "name": "maedana/crmux",
    "url": "https://github.com/maedana/crmux",
    "agent": "Claude Code",
    "description": "Unlike cmux-native plugins, renders a tmux-based sidebar outside cmux itself, surfacing permission mode, repo, branch, and worktree alongside live status for every concurrent Claude Code session",
    "language": "Rust",
    "stars": 21,
    "categories": [
      "Sidebar & Status Pills",
      "Monitoring & Session Restore",
      "Claude Code"
    ]
  },
  {
    "name": "azu/cmux-hub",
    "url": "https://github.com/azu/cmux-hub",
    "agent": "Claude Code",
    "description": "Focuses on post-session review rather than live pills: expose a browser-based diff viewer with inline comments, commit history, and GitHub PR/CI status that other Claude Code plugins omit",
    "language": "TypeScript",
    "stars": 23,
    "categories": [
      "Sidebar & Status Pills",
      "Browser Automation",
      "Claude Code"
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
    "name": "hopchouinard/cmux-plugin",
    "url": "https://github.com/hopchouinard/cmux-plugin",
    "agent": "Claude Code",
    "description": "Uniquely bundles Claude-specific restraint rules alongside tab renaming and live progress bars, nudging the agent toward safer behavior rather than just reporting it",
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
    "name": "eduwass/cru",
    "url": "https://github.com/eduwass/cru",
    "agent": "Claude Code",
    "description": "Targets multi-agent teams rather than single sessions: arrange workers in a labeled grid with a 447-line cmux module, SF Symbol lifecycle phases, and a progress-watcher - unlike single-session Claude Code plugins",
    "language": "TypeScript",
    "categories": [
      "Sidebar & Status Pills",
      "Desktop Notifications",
      "Multi-Agent Orchestration",
      "Claude Code"
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
    "name": "KyleJamesWalker/cc-cmux-plugin",
    "url": "https://github.com/KyleJamesWalker/cc-cmux-plugin",
    "agent": "Claude Code",
    "description": "Prioritizes onboarding over decoration: inject the full cmux command reference into every new session and auto-grant cmux CLI permissions, so the agent can use cmux tools without manual setup",
    "categories": [
      "Sidebar & Status Pills",
      "Desktop Notifications",
      "Themes, Layouts & Config",
      "Claude Code"
    ]
  },
  {
    "name": "jaequery/cmux-diff",
    "url": "https://github.com/jaequery/cmux-diff",
    "agent": "Claude Code",
    "description": "Unlike status-pill plugins, adds a Cursor-style changes panel inside cmux's browser split with syntax-highlighted diffs and AI-generated commit messages as a persistent companion view",
    "language": "TypeScript",
    "categories": [
      "Sidebar & Status Pills",
      "Browser Automation",
      "Claude Code"
    ]
  },
  {
    "name": "wrock/wezterm-agent-cards",
    "url": "https://github.com/wrock/wezterm-agent-cards",
    "agent": "Claude Code",
    "description": "Targets WezTerm users exclusively: render Claude Code sessions as stacked curses-based status cards, unlike cmux-socket plugins that require the cmux sidebar infrastructure",
    "language": "Python",
    "categories": [
      "Sidebar & Status Pills",
      "Monitoring & Session Restore",
      "Claude Code"
    ]
  },
  {
    "name": "Mirksen/cmux-toolkit",
    "url": "https://github.com/Mirksen/cmux-toolkit",
    "agent": "Claude Code",
    "description": "Skips status pills in favour of IDE ergonomics: auto-open edited files in a Vim subpane and toggle a broot file-browser sidebar, turning cmux into a lightweight editor environment",
    "language": "Shell",
    "categories": [
      "Sidebar & Status Pills",
      "Themes, Layouts & Config",
      "Claude Code"
    ]
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
    "name": "guanxm2617/feishu-openclaw-cmux",
    "url": "https://github.com/guanxm2617/feishu-openclaw-cmux",
    "agent": "Claude Code",
    "description": "Bridge cmux sidebar state bidirectionally to Feishu/Lark: poll notifications every 4 seconds, forward as rich Feishu cards, and trigger cmux commands from Feishu messages - the only enterprise-chat integration for sidebar pills",
    "language": "Shell",
    "categories": [
      "Sidebar & Status Pills",
      "Desktop Notifications",
      "Remote & Mobile Access",
      "Claude Code"
    ]
  },
  {
    "name": "HazAT/pi-config",
    "url": "https://github.com/HazAT/pi-config",
    "agent": "Pi",
    "description": "Covers the broadest Pi surface of any plugin: push model, tokens, active tool, and cost to the sidebar via a built-in multi-agent architecture with dedicated planning, scouting, and review subagents",
    "language": "TypeScript",
    "stars": 331,
    "categories": [
      "Sidebar & Status Pills",
      "Desktop Notifications",
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
    "name": "joelhooks/pi-cmux",
    "url": "https://github.com/joelhooks/pi-cmux",
    "agent": "Pi",
    "description": "Adds AI-generated session names via Claude Haiku on top of a 3-second heartbeat, and unlike sasha-computer/pi-cmux, includes explicit worker mode for orchestrator-spawned subagents",
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
    "name": "Attamusc/pi-cmux",
    "url": "https://github.com/Attamusc/pi-cmux",
    "agent": "Pi",
    "description": "Differentiates from other Pi plugins with render throttling to prevent sidebar flicker, dynamic progress estimation, and needs-attention alerts that auto-clear after ten seconds",
    "language": "TypeScript",
    "categories": [
      "Sidebar & Status Pills",
      "Progress Bars & Estimation",
      "Desktop Notifications",
      "Pi"
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
    "name": "simonjohansson/pi-cmux",
    "url": "https://github.com/simonjohansson/pi-cmux",
    "agent": "Pi",
    "description": "Prioritizes simplicity over breadth: expose a single configurable cmux_cli pass-through tool that forwards any argv to cmux, unlike multi-pill Pi plugins that hard-code their event mappings",
    "language": "TypeScript",
    "categories": [
      "Sidebar & Status Pills",
      "Sidebar Logs & Activity Feed",
      "Pi"
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
    "name": "kdcokenny/ocx",
    "url": "https://github.com/kdcokenny/ocx",
    "agent": "OpenCode",
    "description": "Adds portable configuration profile management on top of sidebar status - the only OpenCode plugin that lets you switch full environment profiles with flash triggers, making it production-proven at 520 stars",
    "language": "TypeScript",
    "stars": 669,
    "categories": [
      "Sidebar & Status Pills",
      "OpenCode"
    ]
  },
  {
    "name": "0xCaso/opencode-cmux",
    "url": "https://github.com/0xCaso/opencode-cmux",
    "agent": "OpenCode",
    "description": "Unlike kdcokenny/ocx's profile focus, drives progress from todo completion counts and scopes unread log marks per workspace, giving per-project visibility across parallel OpenCode sessions",
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
    "name": "Attamusc/opencode-cmux",
    "url": "https://github.com/Attamusc/opencode-cmux",
    "agent": "OpenCode",
    "description": "Prioritizes performance over features: delivers ~1-2ms socket latency with render throttling and log rate-limiting, unlike Shell-based OpenCode plugins that lack backpressure controls",
    "language": "TypeScript",
    "categories": [
      "Sidebar & Status Pills",
      "Progress Bars & Estimation",
      "Sidebar Logs & Activity Feed",
      "OpenCode"
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
    "name": "Joehoel/opencode-cmux",
    "url": "https://github.com/Joehoel/opencode-cmux",
    "agent": "OpenCode",
    "description": "Uniquely integrates external project management services: polls Azure DevOps and Jira via Zsh to inject ticket and build status as additional sidebar pills alongside standard OpenCode status",
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
    "name": "block/cmux-amp",
    "url": "https://github.com/block/cmux-amp",
    "agent": "Amp",
    "description": "Wire the official Amp Plugin API to the cmux sidebar with SF Symbol icons for agent state - the only first-party Amp plugin in the list, built and maintained by Block",
    "language": "TypeScript",
    "categories": [
      "Sidebar & Status Pills",
      "Copilot & Amp"
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
    "name": "EtanHey/cmuxlayer",
    "url": "https://github.com/EtanHey/cmuxlayer",
    "agent": "Multi",
    "description": "Expose 22 tightly scoped MCP tools for sidebar updates, progress, split creation, and screen reading - smaller and more auditable than cmux-agent-mcp's 81-tool suite, while still covering multi-agent orchestration",
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
    "name": "hummer98/cmux-team",
    "url": "https://github.com/hummer98/cmux-team",
    "agent": "Claude Code",
    "description": "Display independent real-time progress bars for conductor and each worker sub-agent in a task-queue daemon, letting you distinguish which tier of the hierarchy is blocked",
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
    "name": "HazAT/pi-interactive-subagents",
    "url": "https://github.com/HazAT/pi-interactive-subagents",
    "agent": "Multi",
    "description": "Render elapsed time and live per-agent progress in a TUI widget while sub-agents execute in dedicated panes across cmux, tmux, zellij, or WezTerm - the widest multiplexer coverage of any progress plugin",
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
    "name": "claude-studio/claude-studio",
    "url": "https://github.com/claude-studio/claude-studio",
    "agent": "Claude Code",
    "description": "Parse JSONL transcripts from ~/.claude/projects offline to render cost, token, and session statistics on a standalone dashboard rather than writing live log entries - suited for post-session analysis, not real-time monitoring",
    "language": "TypeScript",
    "categories": [
      "Sidebar Logs & Activity Feed",
      "Monitoring & Session Restore",
      "Claude Code"
    ]
  },
  {
    "name": "Th3Sp3ct3R/cmux-claude-agents",
    "url": "https://github.com/Th3Sp3ct3R/cmux-claude-agents",
    "agent": "Claude Code",
    "description": "Send completion notifications specifically when redirected sub-agent panes finish; uniquely scoped to redirected-pane topology rather than the primary session",
    "language": "Shell",
    "categories": [
      "Desktop Notifications",
      "Multi-Agent Orchestration",
      "Claude Code"
    ]
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
    "name": "bjacobso/pimux",
    "url": "https://github.com/bjacobso/pimux",
    "agent": "Pi",
    "description": "Notify as part of a task state machine managing parallel Pi agents across worktrees; uniquely ties notification events to worktree lifecycle transitions, not just session-level hooks",
    "language": "TypeScript",
    "categories": [
      "Desktop Notifications",
      "Multi-Agent Orchestration",
      "Worktrees & Workspace Management",
      "Pi"
    ]
  },
  {
    "name": "kdcokenny/opencode-workspace",
    "url": "https://github.com/kdcokenny/opencode-workspace",
    "agent": "OpenCode",
    "description": "Bundle OS notifications inside a 16-component harness with planning, delegation, and worktree plugins; the most expansive OpenCode setup - notifications are one piece of a full orchestration suite",
    "language": "TypeScript",
    "stars": 402,
    "categories": [
      "Desktop Notifications",
      "Multi-Agent Orchestration",
      "Worktrees & Workspace Management",
      "OpenCode"
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
    "name": "tadashi-aikawa/copilot-plugin-notify",
    "url": "https://github.com/tadashi-aikawa/copilot-plugin-notify",
    "agent": "Copilot",
    "description": "Emit OSC 777 escape sequences for tool-use approvals and agent-stop alerts with configurable allow/deny rules; uniquely exposes an allow/deny rule set so noisy approval events can be filtered before the notification fires",
    "language": "Shell",
    "categories": [
      "Desktop Notifications",
      "Copilot & Amp"
    ]
  },
  {
    "name": "aannoo/hcom",
    "url": "https://github.com/aannoo/hcom",
    "agent": "Multi",
    "description": "Deliver cross-agent notifications and file-edit collision detection across Claude Code, Gemini CLI, Codex, and OpenCode in a single Rust daemon; the only entry covering four agents simultaneously and the only one that catches edit collisions",
    "language": "Rust",
    "stars": 252,
    "categories": [
      "Desktop Notifications",
      "Multi-Agent Orchestration",
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
    "name": "richardhowes/cmux-mobile",
    "url": "https://github.com/richardhowes/cmux-mobile",
    "description": "Push APNs notifications from cmux to an iOS companion app over Tailscale with full workspace listing and ANSI terminal rendering - uniquely provides native mobile push as the delivery channel",
    "language": "TypeScript",
    "categories": [
      "Desktop Notifications",
      "Remote & Mobile Access"
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
    "name": "Yeachan-Heo/oh-my-claudecode",
    "url": "https://github.com/Yeachan-Heo/oh-my-claudecode",
    "agent": "Claude Code",
    "description": "Enable full autopilot mode with team pipelines, a tri-model advisor (Claude+Codex+Gemini), and tmux worker panes - the highest-starred orchestration framework by a wide margin",
    "language": "TypeScript",
    "stars": 32659,
    "categories": [
      "Multi-Agent Orchestration",
      "Worktrees & Workspace Management",
      "Monitoring & Session Restore",
      "Claude Code"
    ]
  },
  {
    "name": "manaflow-ai/manaflow",
    "url": "https://github.com/manaflow-ai/manaflow",
    "agent": "Multi",
    "description": "Spawn Claude Code, Codex, Gemini, and other agents in parallel VS Code workspaces with git diff view and one-click PR creation - uniquely built around VS Code rather than terminal multiplexers",
    "language": "TypeScript",
    "stars": 1033,
    "categories": [
      "Multi-Agent Orchestration",
      "Multi-Agent / Agent-Agnostic"
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
    "name": "rjwittams/flotilla",
    "url": "https://github.com/rjwittams/flotilla",
    "agent": "Multi",
    "description": "Correlate branches, PRs, issues, and terminal agents across repos into unified work items via a TUI dashboard - addresses multi-repo tracking rather than single-repo task dispatch",
    "language": "Rust",
    "categories": [
      "Multi-Agent Orchestration",
      "Worktrees & Workspace Management",
      "Monitoring & Session Restore",
      "Multi-Agent / Agent-Agnostic"
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
    "name": "dagster-io/erk",
    "url": "https://github.com/dagster-io/erk",
    "agent": "Claude Code",
    "description": "Create implementation plans from AI, execute each in an isolated git worktree, and ship via automated PR submission - uniquely enforces full plan-execute-ship cycle with worktree isolation per task",
    "language": "Python",
    "stars": 81,
    "categories": [
      "Multi-Agent Orchestration",
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
    "name": "Ridgeio/swarm",
    "url": "https://github.com/Ridgeio/swarm",
    "agent": "Claude Code",
    "description": "Coordinate agents across terminals via cmux send with /join-swarm registration, SQLite persistence, and UserPromptSubmit hooks - focused on persistent swarm awareness rather than ephemeral pane dispatch",
    "language": "TypeScript",
    "categories": [
      "Multi-Agent Orchestration",
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
    "name": "TimoKruth/cmux-t3code",
    "url": "https://github.com/TimoKruth/cmux-t3code",
    "agent": "Multi",
    "description": "Embed t3code AI coding GUI as per-workspace chat panels via sidecar Node.js servers on unique ports - uniquely grafts an external coding GUI into each cmux workspace",
    "categories": [
      "Multi-Agent Orchestration",
      "Browser Automation",
      "Worktrees & Workspace Management",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "burggraf/pi-teams",
    "url": "https://github.com/burggraf/pi-teams",
    "agent": "Pi",
    "description": "Turn one Pi agent into a coordinated team with specialist teammates, shared task board, direct messaging, and plan-approval gates - Pi-native alternative to general multi-agent frameworks",
    "language": "TypeScript",
    "stars": 91,
    "categories": [
      "Multi-Agent Orchestration",
      "Pi"
    ]
  },
  {
    "name": "ygrec-app/supreme-leader-skill",
    "url": "https://github.com/ygrec-app/supreme-leader-skill",
    "agent": "Claude Code",
    "description": "Plan subtasks, spawn a 2 - 8 worker grid, monitor via read-screen polling, review deliverables, and dispatch fix iterations - covers the full orchestrator loop in a single skill",
    "language": "Markdown",
    "categories": [
      "Multi-Agent Orchestration",
      "Claude Code"
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
    "name": "jeremyeder/sisi-cmux",
    "url": "https://github.com/jeremyeder/sisi-cmux",
    "agent": "Claude Code",
    "description": "Auto-discover projects and build tmux workspaces with one-key Claude Code integration and checkpoint save/restore - project-bootstrap companion rather than a runtime orchestration skill",
    "language": "TypeScript",
    "categories": [
      "Multi-Agent Orchestration",
      "Claude Code"
    ]
  },
  {
    "name": "halindrome/cmux-tmux-mapping-for-cc",
    "url": "https://github.com/halindrome/cmux-tmux-mapping-for-cc",
    "agent": "Claude Code",
    "description": "Detect tmux vs cmux at runtime and transparently route all panel operations through the correct backend - enables skills written for one multiplexer to work unchanged on the other",
    "language": "Shell",
    "categories": [
      "Multi-Agent Orchestration",
      "Claude Code"
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
    "name": "sdgranger/will-public-claude",
    "url": "https://github.com/sdgranger/will-public-claude",
    "agent": "Claude Code",
    "description": "Ship a plugin marketplace package with five skills: cmux detection, cmux-browser, cmux-parallel, cmux-run, and skillify (auto-generate SKILL.md) - the only multi-skill marketplace bundle",
    "language": "Shell",
    "categories": [
      "Multi-Agent Orchestration",
      "Browser Automation",
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
    "name": "take0x/cmux-skills",
    "url": "https://github.com/take0x/cmux-skills",
    "agent": "Claude Code",
    "description": "Offer two skills: self-referential cmux docs lookup (live cmux -h + scraped cmux.com) and /pane reader for other terminals - the only skill that dynamically scrapes upstream documentation at runtime",
    "language": "Shell",
    "categories": [
      "Multi-Agent Orchestration",
      "Monitoring & Session Restore",
      "Claude Code"
    ]
  },
  {
    "name": "H-Noguchi-josys/cmux-split-plugin",
    "url": "https://github.com/H-Noguchi-josys/cmux-split-plugin",
    "agent": "Claude Code",
    "description": "Provide a /split skill that forks current conversation into a new cmux pane via cmux new-split right + claude -c - minimal single-command conversation forking",
    "language": "Shell",
    "categories": [
      "Multi-Agent Orchestration",
      "Worktrees & Workspace Management",
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
    "name": "basedcorp99/claude-worktree-zsh",
    "url": "https://github.com/basedcorp99/claude-worktree-zsh",
    "agent": "Multi",
    "description": "Provide Zsh helpers launching 5 agents (Claude/Codex/Droid/OpenCode/Pi) in worktrees with cwl dashboard and cwm merge-back - the widest agent coverage of any worktree helper",
    "language": "Shell",
    "categories": [
      "Multi-Agent Orchestration",
      "Worktrees & Workspace Management",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "sanurb/pi-cmux-workflows",
    "url": "https://github.com/sanurb/pi-cmux-workflows",
    "agent": "Pi",
    "description": "Add slash commands for splitting panes with new agent sessions and handing off task context between splits - lightweight entry point for Pi users who want manual-trigger orchestration",
    "language": "TypeScript",
    "categories": [
      "Multi-Agent Orchestration",
      "Browser Automation",
      "Pi"
    ]
  },
  {
    "name": "owizdom/context-brdige-for-cmux",
    "url": "https://github.com/owizdom/context-brdige-for-cmux",
    "agent": "Multi",
    "description": "Run a background daemon that extracts agent context, persists it to SQLite, and auto-injects handoff briefs into new sessions - the only skill addressing cold-start context loss across session boundaries",
    "language": "Go",
    "categories": [
      "Multi-Agent Orchestration",
      "Monitoring & Session Restore",
      "Multi-Agent / Agent-Agnostic"
    ]
  },
  {
    "name": "meengi07/cmux-agent-observer-skill",
    "url": "https://github.com/meengi07/cmux-agent-observer-skill",
    "agent": "Multi",
    "description": "Launch visible worker panes for Codex and OpenCode with optional tmux wrapping and a browser helper - extends cmux orchestration to non-Claude agents that lack native cmux support",
    "language": "Shell",
    "categories": [
      "Multi-Agent Orchestration",
      "Monitoring & Session Restore",
      "Multi-Agent / Agent-Agnostic"
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
    "name": "hashangit/cmux-skill",
    "url": "https://github.com/hashangit/cmux-skill",
    "agent": "Claude Code",
    "description": "Control browser elements by stable ref via snapshot --interactive, applying a notification decision matrix to choose alert vs. pane - the only skill built around element-ref stability rather than XPath/CSS selectors",
    "language": "Shell",
    "categories": [
      "Browser Automation",
      "Claude Code"
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
    "name": "alankyshum/semantic-diff",
    "url": "https://github.com/alankyshum/semantic-diff",
    "agent": "Claude Code",
    "description": "Display a terminal TUI diff viewer that uses AI to semantically group git hunks with SIGUSR1 auto-refresh from Claude Code edits and Mermaid rendering in Ghostty/cmux - semantic grouping distinguishes it from line-level diff tools",
    "language": "Rust",
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
    "name": "doublezz10/figure-viewer",
    "url": "https://github.com/doublezz10/figure-viewer",
    "agent": "OpenCode",
    "description": "Display scientific figures in a cmux browser pane with lightbox zoom, freshness timestamps, and auto-refresh - purpose-built for data-science and research workflows where figures change frequently",
    "language": "JavaScript",
    "categories": [
      "Browser Automation",
      "OpenCode"
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
    "name": "craigsc/cmux",
    "url": "https://github.com/craigsc/cmux",
    "agent": "Claude Code",
    "description": "Wrap the full git worktree lifecycle - create, switch, merge, and teardown - into single shell commands with tab completion and shared git history; sets the UX bar every other plugin is measured against",
    "language": "Shell",
    "stars": 525,
    "categories": [
      "Worktrees & Workspace Management",
      "Claude Code"
    ]
  },
  {
    "name": "aschreifels/cwt",
    "url": "https://github.com/aschreifels/cwt",
    "agent": "Claude Code",
    "description": "Generate worktrees pre-wired to tickets pulled live from Linear, GitHub, or Jira, then walk through setup via an interactive TUI wizard with draft-mode support for work-in-progress branches",
    "language": "Go",
    "categories": [
      "Worktrees & Workspace Management",
      "Claude Code"
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
    "name": "Kaldy14/clui",
    "url": "https://github.com/Kaldy14/clui",
    "agent": "Claude Code",
    "description": "Wrap Claude Code in an Electron GUI where every conversation thread gets its own git worktree, and idle threads are LRU-hibernated to keep resource usage bounded",
    "language": "TypeScript",
    "categories": [
      "Worktrees & Workspace Management",
      "Claude Code"
    ]
  },
  {
    "name": "tasuku43/kra",
    "url": "https://github.com/tasuku43/kra",
    "agent": "Claude Code",
    "description": "Map every open ticket one-to-one to a cmux workspace on disk, auto-creating the worktree when a task opens and removing it when the task closes - ticket state drives filesystem state",
    "language": "Go",
    "categories": [
      "Worktrees & Workspace Management",
      "Claude Code"
    ]
  },
  {
    "name": "wwaIII/proj",
    "url": "https://github.com/wwaIII/proj",
    "agent": "Claude Code",
    "description": "Launch named cmux workspaces through a Rust TUI project picker that marks sessions running Claude Code with [CC] activity badges for at-a-glance fleet visibility",
    "language": "Rust",
    "categories": [
      "Worktrees & Workspace Management",
      "Themes, Layouts & Config",
      "Claude Code"
    ]
  },
  {
    "name": "mateusduraes/ramo",
    "url": "https://github.com/mateusduraes/ramo",
    "agent": "Claude Code",
    "description": "Run ramo new <branch> to create a worktree, execute setup commands, copy env files, and open a cmux workspace - declarative ramo.json config replaces manual multi-step worktree bootstrapping",
    "language": "Go",
    "categories": [
      "Worktrees & Workspace Management",
      "Claude Code"
    ]
  },
  {
    "name": "theodaguier/wt",
    "url": "https://github.com/theodaguier/wt",
    "agent": "Claude Code",
    "description": "Create worktrees from GitHub and Linear issues: wt gh <issue> fetches the title, creates a branch, and opens a cmux tab - fzf picker for selecting from open issues",
    "language": "Shell",
    "categories": [
      "Worktrees & Workspace Management",
      "Claude Code"
    ]
  },
  {
    "name": "morrisclay/ws",
    "url": "https://github.com/morrisclay/ws",
    "agent": "Claude Code",
    "description": "Open or focus cmux workspaces with ws <name>, scaffold new ones with CLAUDE.md and permissions via ws init, and integrate Flox envs plus 1Password CLI secrets per workspace",
    "language": "Shell",
    "categories": [
      "Worktrees & Workspace Management",
      "Themes, Layouts & Config",
      "Claude Code"
    ]
  },
  {
    "name": "javiermolinar/pi-cmux",
    "url": "https://github.com/javiermolinar/pi-cmux",
    "agent": "Pi",
    "description": "Extend Pi sessions with git worktree branching that passes handoff context between agents, plus 12+ slash commands covering pane splits and zoxide-powered directory jumps",
    "language": "TypeScript",
    "stars": 16,
    "categories": [
      "Worktrees & Workspace Management",
      "Themes, Layouts & Config",
      "Pi"
    ]
  },
  {
    "name": "kdcokenny/opencode-worktree",
    "url": "https://github.com/kdcokenny/opencode-worktree",
    "agent": "OpenCode",
    "description": "Spawn a dedicated terminal with OpenCode running inside each new git worktree, sync files via post-checkout hooks, and auto-commit staged changes on worktree deletion",
    "language": "TypeScript",
    "stars": 504,
    "categories": [
      "Worktrees & Workspace Management",
      "OpenCode"
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
    "name": "ehardesty/fish_git_worktree",
    "url": "https://github.com/ehardesty/fish_git_worktree",
    "description": "Supply Fish shell worktree functions (wt-create/list/remove) with cmux workspace integration - the only Fish-specific worktree helper in the list",
    "language": "Fish",
    "categories": [
      "Worktrees & Workspace Management"
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
    "name": "AtAFork/ghostty-claude-code-session-restore",
    "url": "https://github.com/AtAFork/ghostty-claude-code-session-restore",
    "agent": "Claude Code",
    "description": "Snapshot Claude Code session IDs every 2 seconds via launchd, resolve each ID to its cmux surface, and replay the full session layout into the correct panes on relaunch - optimized for Ghostty terminal",
    "language": "Python",
    "stars": 23,
    "categories": [
      "Monitoring & Session Restore",
      "Claude Code"
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
    "name": "theforager/cmux",
    "url": "https://github.com/theforager/cmux",
    "agent": "Claude Code",
    "description": "Provide an interactive tmux session selector with real-time status indicators tuned for low-bandwidth mobile SSH connections - prioritizes minimal rendering over rich dashboards",
    "language": "Shell",
    "categories": [
      "Monitoring & Session Restore",
      "Remote & Mobile Access",
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
    "name": "ensarkovankaya/cmux-mirror",
    "url": "https://github.com/ensarkovakaya/cmux-mirror",
    "description": "Mirror a remote cmux layout to a local instance over SSH with incremental sync support - observability tool focused on remote-to-local layout replication rather than agent state",
    "language": "Python",
    "categories": [
      "Monitoring & Session Restore",
      "Remote & Mobile Access"
    ]
  },
  {
    "name": "hummer98/cmux-remote",
    "url": "https://github.com/hummer98/cmux-remote",
    "description": "Self-host a PWA bridge that streams live workspace state to any browser over WebSocket, rendering panes with xterm.js and supporting surface switching without an SSH tunnel",
    "language": "TypeScript",
    "stars": 6,
    "categories": [
      "Remote & Mobile Access"
    ]
  },
  {
    "name": "elitecoder/cmux-bridge",
    "url": "https://github.com/elitecoder/cmux-bridge",
    "description": "Connect cmux to Slack with read/send/key/watch commands in channels, posting watched surfaces to threads with LaunchAgent auto-start - the only Slack integration for cmux remote control",
    "language": "TypeScript",
    "categories": [
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
    "name": "blueraai/bluera-base",
    "url": "https://github.com/blueraai/bluera-base",
    "agent": "Claude Code",
    "description": "Establish shared multi-language conventions enforced by PostToolUse hooks that run validation and quality gates automatically after every Claude tool call",
    "language": "Shell",
    "categories": [
      "Themes, Layouts & Config",
      "Claude Code"
    ]
  },
  {
    "name": "wolffiex/cmux",
    "url": "https://github.com/wolffiex/cmux",
    "description": "Manage tmux window arrangements through a popup UI featuring a visual carousel, 10 named preset layouts, and AI-generated summaries of each window's current activity",
    "language": "TypeScript",
    "stars": 6,
    "categories": [
      "Themes, Layouts & Config"
    ]
  },
  {
    "name": "stevenocchipinti/raycast-cmux",
    "url": "https://github.com/stevenocchipinti/raycast-cmux",
    "description": "Search, focus, and manage cmux workspaces and panes directly from Raycast with keyboard-driven commands, eliminating the need to touch the mouse or switch apps",
    "language": "TypeScript",
    "categories": [
      "Themes, Layouts & Config"
    ]
  },
  {
    "name": "karlorz/dev-docs-cmux",
    "url": "https://github.com/karlorz/dev-docs-cmux",
    "description": "Fetch and keep current LLM-optimised documentation for cmux dependencies via a make-driven workflow, ensuring agents always have accurate API references in context",
    "language": "Shell",
    "categories": [
      "Themes, Layouts & Config"
    ]
  },
  {
    "name": "jcyamacho/zdotfiles",
    "url": "https://github.com/jcyamacho/zdotfiles",
    "description": "Wire up a Zsh environment with Antidote plugin management, Starship prompt, and opinionated install helpers for cmux, fzf, zoxide, and git-worktree workflows",
    "language": "Zsh",
    "categories": [
      "Themes, Layouts & Config"
    ]
  },
  {
    "name": "chrisliu298/ghostty-config",
    "url": "https://github.com/chrisliu298/ghostty-config",
    "description": "Configure Ghostty with a GitHub Dark theme, Berkeley Mono 18pt, 128 MiB scrollback buffer, and cmux-ready key bindings tuned for long agent sessions",
    "categories": [
      "Themes, Layouts & Config"
    ]
  },
  {
    "name": "danneu/danterm",
    "url": "https://github.com/danneu/danterm",
    "description": "Build a macOS terminal on libghostty with vertical tab strips, split panes, collapsible tab groups, and JSON-serialised layout restore across restarts",
    "language": "Swift",
    "categories": [
      "Themes, Layouts & Config"
    ]
  },
  {
    "name": "davis7dotsh/my-term",
    "url": "https://github.com/davis7dotsh/my-term",
    "description": "Prototype a native macOS terminal emulator with an Arc-style persistent sidebar and long-lived SwiftTerm sessions designed to host cmux workspaces indefinitely",
    "language": "Swift",
    "categories": [
      "Themes, Layouts & Config"
    ]
  },
  {
    "name": "Seungwoo321/cmux-setup",
    "url": "https://github.com/Seungwoo321/cmux-setup",
    "agent": "Claude Code",
    "description": "Register projects and group them into presets, then launch all as cmux workspaces with cmux-setup run <preset> - the only Korean-language project registry and preset launcher for cmux",
    "language": "TypeScript",
    "categories": [
      "Themes, Layouts & Config",
      "Claude Code"
    ]
  },
  {
    "name": "richardhowes/cmux-jump",
    "url": "https://github.com/richardhowes/cmux-jump",
    "description": "Resolve partial directory names via zoxide frecency, check cmux workspaces with 4-tier fuzzy matching, and switch or create with j <partial> - the only zoxide-integrated workspace switcher with 45 tests",
    "language": "Shell",
    "categories": [
      "Themes, Layouts & Config"
    ]
  },
  {
    "name": "earchibald/cmux-layout",
    "url": "https://github.com/earchibald/cmux-layout",
    "description": "Apply declarative layout DSL to live cmux via socket JSON-RPC with a describe command that reads back live topology as a reusable descriptor - bidirectional layout definition and introspection",
    "language": "Swift",
    "categories": [
      "Themes, Layouts & Config"
    ]
  },
  {
    "name": "madlouse/homebrew-ghostty",
    "url": "https://github.com/madlouse/homebrew-ghostty",
    "description": "Install a full AI stack (cmux + Ghostty + Zed + Starship + JetBrainsMono) via a single Homebrew formula with idempotent re-runs and dry-run mode - one-command developer environment bootstrap",
    "language": "Ruby",
    "categories": [
      "Themes, Layouts & Config"
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
    "name": "ipdelete/cmux",
    "url": "https://github.com/ipdelete/cmux",
    "description": "Provide an Electron workspace with file browsing, Monaco editor, Git integration, and Copilot Chat",
    "language": "TypeScript",
    "categories": [
      "Copilot & Amp"
    ]
  }
] as const satisfies readonly AwesomeCmuxProject[];
