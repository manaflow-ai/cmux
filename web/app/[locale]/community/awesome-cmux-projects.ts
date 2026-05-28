export type AwesomeCmuxProjectKind = "native" | "port" | "adjacent";

export type AwesomeCmuxProject = {
  name: string;
  url: string;
  agent?: string;
  description: string;
  language?: string;
  stars?: number;
  kind: AwesomeCmuxProjectKind;
  categories: readonly string[];
};

export const awesomeCmuxSourceUrl = "https://github.com/manaflow-ai/awesome-cmux";
export const awesomeCmuxProjectRows = 452;

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
  "Cross-Platform Ports",
  "Alternatives: tmux-Based",
  "Alternatives: Other Terminals & Workspaces",
  "Alternatives: Forks",
  "Build & Distribution",
  "Upstream Dependencies",
  "Archived"
] as const;

export const awesomeCmuxProjects = [
  {
    "name": "Yeachan-Heo/oh-my-claudecode",
    "url": "https://github.com/Yeachan-Heo/oh-my-claudecode",
    "agent": "Claude Code",
    "description": "Manage tmux worker panes as part of a full autopilot framework with team pipelines and a tri-model advisor - worktree-like isolation via dedicated tmux panes rather than git worktrees",
    "language": "TypeScript",
    "stars": 32659,
    "categories": [
      "Multi-Agent Orchestration",
      "Worktrees & Workspace Management",
      "Monitoring & Session Restore",
      "Claude Code"
    ],
    "kind": "native"
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
      "Multi-Agent / Agent-Agnostic",
      "Build & Distribution"
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
  },
  {
    "name": "HazAT/pi-config",
    "url": "https://github.com/HazAT/pi-config",
    "agent": "Pi",
    "description": "Deliver notifications as part of a full multi-agent architecture with cost tracking and subagent coordination; the most feature-complete Pi config - notifications are one layer of a production-grade orchestration stack",
    "language": "TypeScript",
    "stars": 331,
    "categories": [
      "Sidebar & Status Pills",
      "Desktop Notifications",
      "Multi-Agent Orchestration",
      "Pi"
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
  },
  {
    "name": "hummer98/cmux-remote",
    "url": "https://github.com/hummer98/cmux-remote",
    "description": "Self-host a PWA bridge that streams live workspace state to any browser over WebSocket, rendering panes with xterm.js and supporting surface switching without an SSH tunnel",
    "language": "TypeScript",
    "stars": 6,
    "categories": [
      "Remote & Mobile Access"
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
  },
  {
    "name": "adhyaay-karnwal/cmux",
    "url": "https://github.com/adhyaay-karnwal/cmux",
    "description": "Abandoned fork with Docker isolation and multi-CLI support. TypeScript",
    "categories": [
      "Archived"
    ],
    "kind": "native"
  },
  {
    "name": "agent-browser",
    "url": "https://github.com/vercel-labs/agent-browser",
    "description": "Vercel's browser automation, integrated into cmux  31850",
    "categories": [
      "Upstream Dependencies"
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
  },
  {
    "name": "anhoder/homebrew-repo",
    "url": "https://github.com/anhoder/homebrew-repo",
    "description": "Distribute a cmux-nightly cask via a personal Homebrew tap",
    "language": "Ruby",
    "categories": [
      "Build & Distribution"
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
  },
  {
    "name": "Attamusc/opencode-cmux",
    "url": "https://github.com/Attamusc/opencode-cmux",
    "agent": "OpenCode",
    "description": "Apply rate limiting to log writes so high-frequency tool bursts produce a readable digest rather than a flooding stream, prioritizing signal over completeness during intensive OpenCode sessions",
    "language": "TypeScript",
    "categories": [
      "Sidebar & Status Pills",
      "Progress Bars & Estimation",
      "Sidebar Logs & Activity Feed",
      "OpenCode"
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
  },
  {
    "name": "basedcorp99/claude-worktree-zsh",
    "url": "https://github.com/basedcorp99/claude-worktree-zsh",
    "agent": "Multi",
    "description": "Provide Zsh helpers launching 5 agents (Claude/Codex/Droid/OpenCode/Pi) in worktrees with cwl dashboard and cwm merge-back - the widest agent coverage of any worktree shell helper",
    "language": "Shell",
    "categories": [
      "Multi-Agent Orchestration",
      "Worktrees & Workspace Management",
      "Multi-Agent / Agent-Agnostic"
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
  },
  {
    "name": "chrisliu298/ghostty-config",
    "url": "https://github.com/chrisliu298/ghostty-config",
    "description": "Configure Ghostty with a GitHub Dark theme, Berkeley Mono 18pt, 128 MiB scrollback buffer, and cmux-ready key bindings tuned for long agent sessions",
    "categories": [
      "Themes, Layouts & Config"
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
  },
  {
    "name": "ctaho19/cmux-cursor-work-style",
    "url": "https://github.com/ctaho19/cmux-cursor-work-style",
    "description": "Repository deleted. Previously contained a Cursor aesthetic theme with charcoal/blue colors and Berkeley Mono",
    "categories": [
      "Archived"
    ],
    "kind": "native"
  },
  {
    "name": "dd7200/pomo-tui",
    "url": "https://github.com/dd7200/pomo-tui",
    "description": "Fire cmux notify on Pomodoro phase changes from a terminal TUI timer - the only standalone productivity tool using cmux notifications as its alert mechanism",
    "language": "Go",
    "categories": [
      "Desktop Notifications"
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
  },
  {
    "name": "earchibald/cmux-layout",
    "url": "https://github.com/earchibald/cmux-layout",
    "description": "Apply declarative layout DSL to live cmux via socket JSON-RPC with a describe command that reads back live topology as a reusable descriptor - bidirectional layout definition and introspection",
    "language": "Swift",
    "categories": [
      "Themes, Layouts & Config"
    ],
    "kind": "native"
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
    ],
    "kind": "native"
  },
  {
    "name": "ehardesty/fish_git_worktree",
    "url": "https://github.com/ehardesty/fish_git_worktree",
    "description": "Supply Fish shell worktree functions (wt-create/list/remove) with cmux workspace integration - the only Fish-specific worktree helper in the list",
    "language": "Fish",
    "categories": [
      "Worktrees & Workspace Management"
    ],
    "kind": "native"
  },
  {
    "name": "elitecoder/cmux-bridge",
    "url": "https://github.com/elitecoder/cmux-bridge",
    "description": "Connect cmux to Slack with read/send/key/watch commands in channels, posting watched surfaces to threads with LaunchAgent auto-start - the only Slack integration for cmux remote control",
    "language": "TypeScript",
    "categories": [
      "Remote & Mobile Access"
    ],
    "kind": "native"
  },
  {
    "name": "ensarkovankaya/cmux-mirror",
    "url": "https://github.com/ensarkovakaya/cmux-mirror",
    "description": "Mirror a remote cmux layout to a local instance over SSH with incremental sync support - observability tool focused on remote-to-local layout replication rather than agent state",
    "language": "Python",
    "categories": [
      "Monitoring & Session Restore",
      "Remote & Mobile Access"
    ],
    "kind": "native"
  },
  {
    "name": "erikhazzard/cmux-remote",
    "url": "https://github.com/erikhazzard/cmux-remote",
    "description": "Self-host a remote mirror via local bridge + Cloudflare tunnel with a phone web app over WebSocket for terminal preview and workspace switching - zero-config remote access via tunnel",
    "language": "TypeScript",
    "categories": [
      "Remote & Mobile Access"
    ],
    "kind": "native"
  },
  {
    "name": "eunjae-lee/cmux-worktree",
    "url": "https://github.com/eunjae-lee/cmux-worktree",
    "description": "Drive worktree creation from a declarative YAML workspace definition, supporting custom pre/post workflows, configurable split layouts, and per-pane isolated browser storage",
    "language": "TypeScript",
    "categories": [
      "Worktrees & Workspace Management",
      "Themes, Layouts & Config"
    ],
    "kind": "native"
  },
  {
    "name": "EverybodyBusiness/cmux-browser-first",
    "url": "https://github.com/EverybodyBusiness/cmux-browser-first",
    "agent": "Claude Code",
    "description": "Force cmux browser tools to always be prioritized via three slash commands (/browse, /browse-check, /browse-compare) - the only plugin that elevates browser to the default tool choice in Korean",
    "categories": [
      "Browser Automation",
      "Claude Code"
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
  },
  {
    "name": "H-Noguchi-josys/cmux-split-plugin",
    "url": "https://github.com/H-Noguchi-josys/cmux-split-plugin",
    "agent": "Claude Code",
    "description": "Fork the current conversation into a new cmux pane via /split skill using cmux new-split right + claude -c - minimal single-command conversation branching for parallel exploration",
    "language": "Shell",
    "categories": [
      "Multi-Agent Orchestration",
      "Worktrees & Workspace Management",
      "Claude Code"
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
  },
  {
    "name": "jaequery/cmux-diff",
    "url": "https://github.com/jaequery/cmux-diff",
    "agent": "Claude Code",
    "description": "Show Shiki-powered syntax-highlighted diffs in a browser split with multi-file selection and AI-generated commit message suggestions - distinct from azu/cmux-hub by pairing diff viewing with commit authoring",
    "language": "TypeScript",
    "categories": [
      "Sidebar & Status Pills",
      "Browser Automation",
      "Claude Code"
    ],
    "kind": "native"
  },
  {
    "name": "jcyamacho/zdotfiles",
    "url": "https://github.com/jcyamacho/zdotfiles",
    "description": "Wire up a Zsh environment with Antidote plugin management, Starship prompt, and opinionated install helpers for cmux, fzf, zoxide, and git-worktree workflows",
    "language": "Zsh",
    "categories": [
      "Themes, Layouts & Config"
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
  },
  {
    "name": "karlorz/dev-docs-cmux",
    "url": "https://github.com/karlorz/dev-docs-cmux",
    "description": "Fetch and keep current LLM-optimised documentation for cmux dependencies via a make-driven workflow, ensuring agents always have accurate API references in context",
    "language": "Shell",
    "categories": [
      "Themes, Layouts & Config"
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
  },
  {
    "name": "lawrencecchen/cmux-env",
    "url": "https://github.com/lawrencecchen/cmux-env",
    "description": "Coordinate shared environment variables across shells and projects through a lightweight daemon with prompt hooks",
    "language": "Rust",
    "categories": [
      "Build & Distribution"
    ],
    "kind": "native"
  },
  {
    "name": "lawrencecchen/cmux-proxy",
    "url": "https://github.com/lawrencecchen/cmux-proxy",
    "description": "Route HTTP/WebSocket/TCP traffic through a header-based reverse proxy with per-workspace network isolation",
    "language": "Rust",
    "categories": [
      "Build & Distribution"
    ],
    "kind": "native"
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
    ],
    "kind": "native"
  },
  {
    "name": "madlouse/homebrew-ghostty",
    "url": "https://github.com/madlouse/homebrew-ghostty",
    "description": "Install a full AI stack (cmux + Ghostty + Zed + Starship + JetBrainsMono) via a single Homebrew formula with idempotent re-runs and dry-run mode - one-command developer environment bootstrap",
    "language": "Ruby",
    "categories": [
      "Themes, Layouts & Config"
    ],
    "kind": "native"
  },
  {
    "name": "manaflow-ai/chromium",
    "url": "https://github.com/manaflow-ai/chromium",
    "description": "Build a Chromium content shell for cmux's browser engine with prebuilt framework downloads for plugin developers",
    "language": "Obj-C++",
    "categories": [
      "Build & Distribution"
    ],
    "kind": "native"
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
    ],
    "kind": "native"
  },
  {
    "name": "manaflow-ai/homebrew-cmux",
    "url": "https://github.com/manaflow-ai/homebrew-cmux",
    "description": "Provide the official Homebrew tap for cmux with stable and nightly casks maintained by Manaflow",
    "language": "Ruby",
    "categories": [
      "Build & Distribution"
    ],
    "kind": "native"
  },
  {
    "name": "manaflow-ai/vscode",
    "url": "https://github.com/manaflow-ai/vscode",
    "description": "Fork VS Code to replace the web terminal with a cmux backend for code serve-web sessions",
    "categories": [
      "Build & Distribution"
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
  },
  {
    "name": "mateusduraes/ramo",
    "url": "https://github.com/mateusduraes/ramo",
    "agent": "Claude Code",
    "description": "Run ramo new to create a worktree, execute setup commands, copy env files, and open a cmux workspace - declarative ramo.json config replaces manual multi-step worktree bootstrapping",
    "language": "Go",
    "categories": [
      "Worktrees & Workspace Management",
      "Claude Code"
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
      "Themes, Layouts & Config",
      "Multi-Agent / Agent-Agnostic"
    ],
    "kind": "native"
  },
  {
    "name": "miraoto/cmux-cheatsheet",
    "url": "https://github.com/miraoto/cmux-cheatsheet",
    "description": "Provide c-help CLI: offline searchable cheatsheet for all cmux keyboard shortcuts, CLI commands, sidebar APIs, browser automation, and env vars in English and Japanese",
    "language": "Shell",
    "categories": [
      "Themes, Layouts & Config"
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    "kind": "native",
    "agent": "Multi-Agent / Agent-Agnostic"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    "kind": "native",
    "agent": "Multi-Agent / Agent-Agnostic"
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
    ],
    "kind": "native"
  },
  {
    "name": "richardhowes/cmux-jump",
    "url": "https://github.com/richardhowes/cmux-jump",
    "description": "Resolve partial directory names via zoxide frecency, check cmux workspaces with 4-tier fuzzy matching, and switch or create with j - the only zoxide-integrated workspace switcher with 45 tests",
    "language": "Shell",
    "categories": [
      "Themes, Layouts & Config"
    ],
    "kind": "native"
  },
  {
    "name": "richardhowes/cmux-mobile",
    "url": "https://github.com/richardhowes/cmux-mobile",
    "description": "Provide an iOS companion app (React Native/Expo) over Tailscale with full workspace listing, ANSI terminal rendering, keyboard shortcuts, and APNs push notifications - the most feature-complete mobile client",
    "language": "TypeScript",
    "categories": [
      "Desktop Notifications",
      "Remote & Mobile Access"
    ],
    "kind": "native"
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
    ],
    "kind": "native"
  },
  {
    "name": "rjwittams/flotilla",
    "url": "https://github.com/rjwittams/flotilla",
    "agent": "Multi",
    "description": "Correlate agents, branches, and PRs across multiple repos into unified work items via a TUI dashboard - cross-repo aggregation makes it distinct from single-workspace monitoring tools",
    "language": "Rust",
    "categories": [
      "Multi-Agent Orchestration",
      "Worktrees & Workspace Management",
      "Monitoring & Session Restore",
      "Multi-Agent / Agent-Agnostic"
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
  },
  {
    "name": "sdgranger/will-public-claude",
    "url": "https://github.com/sdgranger/will-public-claude",
    "agent": "Claude Code",
    "description": "Include a cmux-browser skill in a 5-skill marketplace package that also covers parallel execution and auto-skill generation - distinct from single-purpose browser plugins by bundling browser alongside orchestration",
    "language": "Shell",
    "categories": [
      "Multi-Agent Orchestration",
      "Browser Automation",
      "Claude Code"
    ],
    "kind": "native"
  },
  {
    "name": "Seungwoo321/cmux-setup",
    "url": "https://github.com/Seungwoo321/cmux-setup",
    "agent": "Claude Code",
    "description": "Register projects and group them into presets, then launch all as cmux workspaces with cmux-setup run - the only Korean-language project registry and preset launcher for cmux",
    "language": "TypeScript",
    "categories": [
      "Themes, Layouts & Config",
      "Claude Code"
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
  },
  {
    "name": "stevenocchipinti/raycast-cmux",
    "url": "https://github.com/stevenocchipinti/raycast-cmux",
    "description": "Search, focus, and manage cmux workspaces and panes directly from Raycast with keyboard-driven commands, eliminating the need to touch the mouse or switch apps",
    "language": "TypeScript",
    "categories": [
      "Themes, Layouts & Config"
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
  },
  {
    "name": "TimoKruth/cmux-t3code",
    "url": "https://github.com/TimoKruth/cmux-t3code",
    "agent": "Multi",
    "description": "Embed a t3code AI coding GUI in cmux browser panes via sidecar Node.js servers on unique ports - uniquely grafts an external coding interface into the browser surface",
    "categories": [
      "Multi-Agent Orchestration",
      "Browser Automation",
      "Worktrees & Workspace Management",
      "Multi-Agent / Agent-Agnostic"
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
  },
  {
    "name": "wangyuxinwhy/agent-skills",
    "url": "https://github.com/wangyuxinwhy/agent-skills",
    "agent": "Multi",
    "description": "Deliver framework-agnostic skills symlinked into Claude Code, Codex, Coco/Trae, or OpenCode with cmux orchestration and Feishu/Lark CLI integration - the only skill set targeting five agent runtimes",
    "categories": [
      "Multi-Agent Orchestration",
      "Multi-Agent / Agent-Agnostic"
    ],
    "kind": "native"
  },
  {
    "name": "webkaz/cmux-intel-builds",
    "url": "https://github.com/webkaz/cmux-intel-builds",
    "description": "Automate Intel Mac x86_64 builds by polling upstream releases every 6 hours and publishing unsigned DMGs",
    "categories": [
      "Build & Distribution"
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
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
    ],
    "kind": "native"
  },
  {
    "name": "mkurman/cmux-windows",
    "url": "https://github.com/mkurman/cmux-windows",
    "description": "Provide a native Windows terminal with ConPTY, split panes, workspace sidebar, OSC notifications, session persistence, and a named-pipe CLI API",
    "language": "C#",
    "stars": 154,
    "categories": [
      "Cross-Platform Ports"
    ],
    "kind": "port"
  },
  {
    "name": "amirlehmam/wmux",
    "url": "https://github.com/amirlehmam/wmux",
    "description": "Build an Electron + xterm.js + ConPTY terminal with CDP proxy for browser integration, auto-injected Claude Code hooks, and a named-pipe API compatible with cmux commands",
    "language": "TypeScript",
    "stars": 85,
    "categories": [
      "Cross-Platform Ports"
    ],
    "kind": "port"
  },
  {
    "name": "no1msd/seance",
    "url": "https://github.com/no1msd/seance",
    "description": "Build a GTK4 Linux terminal multiplexer that auto-detects Claude Code, Codex, and Pi sessions, tracking status, permission waits, task completions, desktop notifications, and unread state without dotfile setup",
    "language": "Zig",
    "stars": 48,
    "categories": [
      "Cross-Platform Ports"
    ],
    "kind": "port"
  },
  {
    "name": "cai0baa/cmux-for-linux",
    "url": "https://github.com/cai0baa/cmux-for-linux",
    "description": "Deliver a cross-platform Tauri workspace with React and xterm.js, now branded ptrcode, with workspaces and resizable splits",
    "language": "TypeScript",
    "stars": 33,
    "categories": [
      "Cross-Platform Ports"
    ],
    "kind": "port"
  },
  {
    "name": "bradwilson331/cmux-linux",
    "url": "https://github.com/bradwilson331/cmux-linux",
    "description": "Port cmux to Linux with Rust, GTK4, GPU-accelerated Ghostty rendering, CDP browser automation, and a 34-subcommand socket CLI",
    "language": "Rust",
    "stars": 27,
    "categories": [
      "Cross-Platform Ports"
    ],
    "kind": "port"
  },
  {
    "name": "douglas/cmux-gtk",
    "url": "https://github.com/douglas/cmux-gtk",
    "description": "Provide a full GTK4/libadwaita port with the same socket API (V1 60 commands + V2 210+ methods), WebKit6 browser, and cmux ssh for remote workspaces - closest feature parity with macOS cmux",
    "language": "Rust",
    "stars": 10,
    "categories": [
      "Cross-Platform Ports"
    ],
    "kind": "port"
  },
  {
    "name": "wshmkr/astral-terminal",
    "url": "https://github.com/wshmkr/astral-terminal",
    "description": "Build a Windows + WSL terminal inspired by cmux, with split panes, workspaces, browser panel, Claude Code hook notifications, restart-safe scrollback, and planned CLI scripting",
    "language": "TypeScript",
    "stars": 6,
    "categories": [
      "Cross-Platform Ports"
    ],
    "kind": "port"
  },
  {
    "name": "aasm3535/wmux",
    "url": "https://github.com/aasm3535/wmux",
    "description": "Build a WinUI 3 port with xterm.js, vertical sidebar, split panes, OSC notifications, WebView2 browser, and native Mica backdrop",
    "language": "C#",
    "categories": [
      "Cross-Platform Ports"
    ],
    "kind": "port"
  },
  {
    "name": "anurag-arjun/cove",
    "url": "https://github.com/anurag-arjun/cove",
    "description": "Fork Ghostty's GTK frontend adding a vertical workspace sidebar, keyboard navigation, planned socket API, and WebKitGTK browser",
    "language": "Zig",
    "categories": [
      "Cross-Platform Ports"
    ],
    "kind": "port"
  },
  {
    "name": "asermax/seemux",
    "url": "https://github.com/asermax/seemux",
    "description": "Provide a GTK4 terminal with tabbed sidebar, real-time Claude Code status, tab groups, quake dropdown, agent teams, and full session persistence",
    "language": "Rust",
    "categories": [
      "Cross-Platform Ports"
    ],
    "kind": "port"
  },
  {
    "name": "dcieslak19973/wmux",
    "url": "https://github.com/dcieslak19973/wmux",
    "description": "Deliver a Tauri v2 + ConPTY terminal with OSC 9/99/777 notification parsing, sidebar metadata, session persistence, and a tmux.exe compatibility shim for migration",
    "language": "JavaScript",
    "categories": [
      "Cross-Platform Ports"
    ],
    "kind": "port"
  },
  {
    "name": "Kazsuto/wmux",
    "url": "https://github.com/Kazsuto/wmux",
    "description": "Provide a native Rust + D3D12/wgpu terminal with 80+ JSON-RPC v2 commands over Named Pipes (HMAC-SHA256 auth), Ghostty-compatible config, and command palette",
    "language": "Rust",
    "categories": [
      "Cross-Platform Ports"
    ],
    "kind": "port"
  },
  {
    "name": "LucasPC-hub/lcmux",
    "url": "https://github.com/LucasPC-hub/lcmux",
    "description": "Build a GTK4/VTE4 port with NixOS flake, Arch packages, and WebKitGTK 6.0 browser - wire-compatible with macOS cmux socket protocol for plugin reuse",
    "language": "Rust",
    "categories": [
      "Cross-Platform Ports"
    ],
    "kind": "port"
  },
  {
    "name": "nice-bills/lmux",
    "url": "https://github.com/nice-bills/lmux",
    "description": "Build a pure-C GTK4/VTE terminal with split browser panes, D-Bus notifications, toggleable sidebar, and vim-style navigation",
    "language": "C",
    "categories": [
      "Cross-Platform Ports"
    ],
    "kind": "port"
  },
  {
    "name": "shogotomita/cmux-win",
    "url": "https://github.com/shogotomita/cmux-win",
    "description": "Build a WPF/ConPTY terminal with workspace splitting, sidebar pills, Claude Code hooks, and a 28-method named-pipe IPC server",
    "language": "C#",
    "categories": [
      "Cross-Platform Ports"
    ],
    "kind": "port"
  },
  {
    "name": "TRINITXX/cmux-windows",
    "url": "https://github.com/TRINITXX/cmux-windows",
    "description": "Fork mkurman's implementation adding Claude Code hooks, Zen mode, Dracula/One Dark themes, and command log replay",
    "language": "C#",
    "categories": [
      "Cross-Platform Ports"
    ],
    "kind": "port"
  },
  {
    "name": "Octane0411/open-vibe-island",
    "url": "https://github.com/Octane0411/open-vibe-island",
    "description": "Monitor Claude Code, Codex, and OpenCode from a native macOS menu-bar companion that can watch terminal, Ghostty, cmux, Kakoune, and iTerm workflows without depending on cmux APIs",
    "language": "Swift",
    "stars": 1149,
    "categories": [
      "Alternatives: Other Terminals & Workspaces"
    ],
    "kind": "adjacent"
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
      "Claude Code",
      "Alternatives: tmux-Based"
    ],
    "kind": "adjacent"
  },
  {
    "name": "vakovalskii/codbash",
    "url": "https://github.com/vakovalskii/codbash",
    "description": "Provide a browser dashboard for searching, replaying, tagging, and resuming Claude Code, Codex, Pi, Cursor, OpenCode, Kiro, and Copilot sessions, with cmux as one launch target",
    "language": "JavaScript",
    "stars": 212,
    "categories": [
      "Alternatives: Other Terminals & Workspaces"
    ],
    "kind": "adjacent"
  },
  {
    "name": "adibhanna/tsm",
    "url": "https://github.com/adibhanna/tsm",
    "description": "Manage persistent terminal sessions as background daemons with a native cmux backend for workspaces, splits, and sidebar sync",
    "language": "Go",
    "stars": 157,
    "categories": [
      "Alternatives: Other Terminals & Workspaces"
    ],
    "kind": "adjacent"
  },
  {
    "name": "sverrirsig/claude-control",
    "url": "https://github.com/sverrirsig/claude-control",
    "description": "Build a macOS dashboard for discovering Claude Code sessions, showing git and PR status, approving prompts, and focusing terminal tabs across iTerm2, Terminal, kitty, WezTerm, cmux, and others",
    "language": "TypeScript",
    "stars": 119,
    "categories": [
      "Alternatives: Other Terminals & Workspaces"
    ],
    "kind": "adjacent"
  },
  {
    "name": "ClipboardHealth/groundcrew",
    "url": "https://github.com/ClipboardHealth/groundcrew",
    "description": "Dispatch Linear tickets to AI coding agents in sandboxed git worktrees with per-ticket status, resume tracking, and optional cmux workspace mapping for visible local execution",
    "language": "TypeScript",
    "stars": 32,
    "categories": [
      "Alternatives: Other Terminals & Workspaces"
    ],
    "kind": "adjacent"
  },
  {
    "name": "maedana/crmux",
    "url": "https://github.com/maedana/crmux",
    "description": "Provide a tmux sidebar with live Claude Code status, permission mode, and vim-like navigation with scriptable RPC",
    "language": "Rust",
    "stars": 21,
    "categories": [
      "Alternatives: tmux-Based"
    ],
    "kind": "adjacent"
  },
  {
    "name": "wolffiex/cmux",
    "url": "https://github.com/wolffiex/cmux",
    "description": "Manage tmux window arrangements through a popup UI featuring a visual carousel, 10 named preset layouts, and AI-generated summaries of each window's current activity",
    "language": "TypeScript",
    "stars": 6,
    "categories": [
      "Themes, Layouts & Config",
      "Alternatives: tmux-Based"
    ],
    "kind": "adjacent"
  },
  {
    "name": "julo15/seshctl",
    "url": "https://github.com/julo15/seshctl",
    "description": "Track terminal-based coding sessions across Terminal.app, iTerm2, VS Code, Cursor, Warp, Ghostty, and cmux through a native menu-bar app and CLI",
    "language": "Swift",
    "stars": 5,
    "categories": [
      "Alternatives: Other Terminals & Workspaces"
    ],
    "kind": "adjacent"
  },
  {
    "name": "danneu/danterm",
    "url": "https://github.com/danneu/danterm",
    "description": "Build a macOS terminal on libghostty with vertical tab strips, split panes, collapsible tab groups, and JSON-serialised layout restore across restarts",
    "language": "Swift",
    "categories": [
      "Themes, Layouts & Config",
      "Alternatives: Other Terminals & Workspaces"
    ],
    "kind": "adjacent"
  },
  {
    "name": "davis7dotsh/my-term",
    "url": "https://github.com/davis7dotsh/my-term",
    "description": "Prototype a native macOS terminal emulator with an Arc-style persistent sidebar and long-lived SwiftTerm sessions designed to host cmux workspaces indefinitely",
    "language": "Swift",
    "categories": [
      "Themes, Layouts & Config",
      "Alternatives: Other Terminals & Workspaces"
    ],
    "kind": "adjacent"
  },
  {
    "name": "Diogenesoftoronto/dellij",
    "url": "https://github.com/Diogenesoftoronto/dellij",
    "description": "Manage parallel agents via Zellij tabs where each workspace maps to a git worktree with a WASM status plugin, optional GPUI GUI, and Android app via Convex",
    "language": "Rust",
    "categories": [
      "Alternatives: Other Terminals & Workspaces"
    ],
    "kind": "adjacent"
  },
  {
    "name": "ipdelete/cmux",
    "url": "https://github.com/ipdelete/cmux",
    "agent": "Copilot & Amp",
    "description": "Provide an Electron workspace with file browsing, Monaco editor, Git integration, and Copilot Chat",
    "language": "TypeScript",
    "categories": [
      "Copilot & Amp",
      "Alternatives: Other Terminals & Workspaces"
    ],
    "kind": "adjacent"
  },
  {
    "name": "israeligal/cmux-file-explorer",
    "url": "https://github.com/israeligal/cmux-file-explorer",
    "description": "Add a file explorer sidebar, native text editor, and CWD sync between explorer and terminal panes. Swift",
    "categories": [
      "Alternatives: Forks"
    ],
    "kind": "adjacent"
  },
  {
    "name": "jeremyeder/sisi-cmux",
    "url": "https://github.com/jeremyeder/sisi-cmux",
    "agent": "Claude Code",
    "description": "Auto-discover projects and build tmux workspaces with one-key Claude Code integration and checkpoint save/restore - project-bootstrap companion rather than a runtime orchestration skill",
    "language": "TypeScript",
    "categories": [
      "Multi-Agent Orchestration",
      "Claude Code",
      "Alternatives: tmux-Based"
    ],
    "kind": "adjacent"
  },
  {
    "name": "Kaldy14/clui",
    "url": "https://github.com/Kaldy14/clui",
    "agent": "Claude Code",
    "description": "Wrap Claude Code in an Electron GUI where every conversation thread gets its own git worktree, and idle threads are LRU-hibernated to keep resource usage bounded",
    "language": "TypeScript",
    "categories": [
      "Worktrees & Workspace Management",
      "Claude Code",
      "Alternatives: Other Terminals & Workspaces"
    ],
    "kind": "adjacent"
  },
  {
    "name": "kght6123/madori",
    "url": "https://github.com/kght6123/madori",
    "description": "Provide a browser-based terminal multiplexer (Node.js + React + xterm.js) with vertical tab sidebar, WebGL rendering, and OSC notifications - Japanese-language alternative to native terminals",
    "language": "TypeScript",
    "categories": [
      "Alternatives: Other Terminals & Workspaces"
    ],
    "kind": "adjacent"
  },
  {
    "name": "llv22/cmux_forward",
    "url": "https://github.com/llv22/cmux_forward",
    "description": "Add working-directory restore for Bash sessions. One patch over upstream. Swift",
    "categories": [
      "Alternatives: Forks"
    ],
    "kind": "adjacent"
  },
  {
    "name": "Pollux-Studio/maxc",
    "url": "https://github.com/Pollux-Studio/maxc",
    "description": "Combine terminal multiplexing, embedded browser, task orchestration, and a programmable CLI in a Tauri workspace",
    "language": "Rust",
    "categories": [
      "Alternatives: Other Terminals & Workspaces"
    ],
    "kind": "adjacent"
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
      "Claude Code",
      "Alternatives: tmux-Based"
    ],
    "kind": "adjacent"
  },
  {
    "name": "Tom-R-Main/execuTerm",
    "url": "https://github.com/Tom-R-Main/execuTerm",
    "description": "Build a native macOS app on cmux + libghostty with a task-board dashboard synced from ExecuFunction SaaS, context injection, and semantic search",
    "language": "Swift",
    "categories": [
      "Alternatives: Other Terminals & Workspaces"
    ],
    "kind": "adjacent"
  },
  {
    "name": "vcabeli/wezmux",
    "url": "https://github.com/vcabeli/wezmux",
    "description": "Fork WezTerm adding cmux-inspired workspace management: persistent sidebar, git/PR metadata, OSC 7777 agent status, blue ring notifications, and auto-injected Claude Code + Codex hooks",
    "language": "Rust",
    "categories": [
      "Alternatives: Other Terminals & Workspaces"
    ],
    "kind": "adjacent"
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
      "Claude Code",
      "Alternatives: Other Terminals & Workspaces"
    ],
    "kind": "adjacent"
  }
] as const satisfies readonly AwesomeCmuxProject[];
