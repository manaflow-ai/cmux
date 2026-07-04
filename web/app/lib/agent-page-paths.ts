import { locales } from "../../i18n/routing";
import { comparePages, comparePath } from "./compare-pages";
import type { ComparePageKey } from "./compare-pages";

export type AgentPageFormat = "md" | "txt";

export type AgentPageVariant =
  | {
      kind: "page";
      format: AgentPageFormat;
      requestedPath: string;
      canonicalPath: string;
    }
  | {
      kind: "llms";
      requestedPath: string;
    };

const extensionPattern = /\.(md|txt)$/i;
const reservedTextRoutes = new Set(["/robots.txt"]);
const blockedPrefixes = [
  "/api",
  "/_next",
  "/_vercel",
  "/agent-page-variant",
  "/handler",
];
const englishOnlyPages = [
  "/privacy-policy",
  "/terms-of-service",
  "/eula",
] as const;

const comparePageTitles = {
  bestTerminalForAgents: "Best terminal for AI coding agents",
  cmuxVsAlacritty: "cmux vs Alacritty",
  cmuxVsConductor: "cmux vs Conductor",
  cmuxVsCursor: "cmux vs Cursor",
  cmuxVsDevin: "cmux vs Devin",
  cmuxVsGhostty: "cmux vs Ghostty",
  cmuxVsHerdr: "cmux vs Herdr",
  cmuxVsIterm2: "cmux vs iTerm2",
  cmuxVsKitty: "cmux vs Kitty",
  cmuxVsOpencode: "cmux vs OpenCode",
  cmuxVsSuperset: "cmux vs Superset",
  cmuxVsTmux: "cmux vs tmux",
  cmuxVsVscode: "cmux vs VS Code",
  cmuxVsWarp: "cmux vs Warp",
  cmuxVsWezterm: "cmux vs WezTerm",
  cmuxVsWindsurf: "cmux vs Windsurf",
  cmuxVsZed: "cmux vs Zed",
  multipleClaudeAgents: "How to run multiple Claude Code agents in parallel",
} satisfies Record<ComparePageKey, string>;

const agentReadableComparePages = comparePages.map((page) => ({
  path: comparePath(page.slug),
  title: comparePageTitles[page.key],
}));

export const agentReadablePages = [
  { path: "/", title: "Home" },
  { path: "/ios", title: "cmux iOS" },
  { path: "/blog", title: "Blog" },
  {
    path: "/blog/claude-code-best-worktree-manager",
    title: "Claude Code Is The Best Worktree Manager",
  },
  { path: "/blog/cmux-home", title: "cmux home" },
  { path: "/blog/cmux-history", title: "cmux history" },
  { path: "/blog/cmux-finder", title: "Introducing cmux Finder" },
  { path: "/blog/cmux-vault", title: "cmux Vault" },
  { path: "/blog/passkey-auth", title: "Passkey auth in the cmux browser" },
  { path: "/blog/task-manager", title: "Task Manager in cmux" },
  { path: "/blog/markdown-viewer", title: "A better markdown viewer in cmux" },
  { path: "/blog/unread-shortcuts", title: "Unread workspace shortcuts in cmux" },
  { path: "/blog/session-restore", title: "Session restore in cmux" },
  { path: "/blog/cmux-ssh", title: "cmux SSH" },
  {
    path: "/blog/cmux-claude-teams",
    title: "Claude Code teammate agents as native cmux panes",
  },
  {
    path: "/blog/cmux-omo",
    title: "oh-my-openagent subagents as native cmux panes",
  },
  { path: "/blog/gpl", title: "cmux is now GPL" },
  { path: "/blog/cmd-shift-u", title: "Cmd+Shift+U" },
  { path: "/blog/zen-of-cmux", title: "The Zen of cmux" },
  { path: "/blog/show-hn-launch", title: "Launching cmux on Show HN" },
  { path: "/blog/introducing-cmux", title: "Introducing cmux" },
  { path: "/docs", title: "Docs" },
  { path: "/docs/getting-started", title: "Getting Started" },
  { path: "/docs/concepts", title: "Concepts" },
  { path: "/docs/workspace-groups", title: "Workspace Groups" },
  { path: "/docs/configuration", title: "Configuration" },
  { path: "/docs/textbox", title: "TextBox" },
  { path: "/docs/custom-commands", title: "Custom Commands" },
  { path: "/docs/dock", title: "Dock" },
  { path: "/docs/keyboard-shortcuts", title: "Keyboard Shortcuts" },
  { path: "/docs/api", title: "CLI Reference" },
  { path: "/docs/browser-automation", title: "Browser Automation" },
  { path: "/docs/skills", title: "Skills" },
  { path: "/docs/notifications", title: "Notifications" },
  { path: "/docs/ssh", title: "SSH" },
  { path: "/docs/ios", title: "iOS App" },
  {
    path: "/docs/agent-integrations/claude-code-teams",
    title: "Claude Code Teams",
  },
  {
    path: "/docs/agent-integrations/oh-my-opencode",
    title: "oh-my-opencode",
  },
  {
    path: "/docs/agent-integrations/oh-my-codex",
    title: "oh-my-codex",
  },
  {
    path: "/docs/agent-integrations/oh-my-claudecode",
    title: "oh-my-claudecode",
  },
  { path: "/docs/changelog", title: "Changelog" },
  { path: "/community", title: "Community" },
  { path: "/wall-of-love", title: "Wall of Love" },
  { path: "/nightly", title: "Nightly" },
  { path: "/assets", title: "Brand Assets" },
  { path: "/guides", title: "Guides" },
  { path: "/compare", title: "Compare cmux" },
  ...agentReadableComparePages,
  { path: "/best-terminal-for-mac", title: "Best terminal for Mac" },
  { path: "/built-on-ghostty", title: "Built on Ghostty" },
  { path: "/agents", title: "Terminal for coding agents" },
  { path: "/agents/claude-code", title: "Terminal for Claude Code" },
  { path: "/agents/codex", title: "Terminal for Codex CLI" },
  { path: "/agents/opencode", title: "Terminal for OpenCode" },
  { path: "/agents/gemini-cli", title: "Terminal for Gemini CLI" },
  { path: "/agents/aider", title: "Terminal for Aider" },
  { path: "/agents/amp", title: "Terminal for Amp" },
  { path: "/agents/cursor-cli", title: "Terminal for Cursor CLI" },
  { path: "/privacy-policy", title: "Privacy Policy" },
  { path: "/terms-of-service", title: "Terms of Service" },
  { path: "/eula", title: "EULA" },
] as const;

export function resolveAgentPageVariant(
  rawPath: string | null,
): AgentPageVariant | null {
  if (!rawPath) {
    return null;
  }

  const requestedPath = normalizeRequestedPath(rawPath);
  if (!requestedPath) {
    return null;
  }

  if (requestedPath === "/llms.txt") {
    return { kind: "llms", requestedPath };
  }

  if (
    reservedTextRoutes.has(requestedPath) ||
    blockedPrefixes.some(
      (prefix) => requestedPath === prefix || requestedPath.startsWith(`${prefix}/`),
    )
  ) {
    return null;
  }

  const extension = requestedPath.match(extensionPattern)?.[1]?.toLowerCase();
  if (extension !== "md" && extension !== "txt") {
    return null;
  }

  const canonicalPath = normalizeCanonicalPagePath(
    requestedPath.slice(0, -extension.length - 1),
  );
  if (!canonicalPath || !isKnownAgentReadablePage(canonicalPath)) {
    return null;
  }

  return {
    kind: "page",
    format: extension,
    requestedPath,
    canonicalPath,
  };
}

export function isAgentPageVariantPath(pathname: string): boolean {
  return resolveAgentPageVariant(pathname) !== null;
}

export function variantPathForPage(
  canonicalPath: string,
  format: AgentPageFormat,
): string {
  return canonicalPath === "/" ? `/index.${format}` : `${canonicalPath}.${format}`;
}

export function buildLlmsText(origin: string): string {
  const lines = [
    "# cmux",
    "",
    "> cmux is a free and open source (GPL), fully scriptable native macOS terminal built on libghostty, purpose-built for running AI coding agents. Every action is available through a CLI and a Unix socket API, so agents can drive the terminal itself. It works with the CLI agents you already use (Claude Code, Codex, OpenCode, Gemini CLI, Aider, and any CLI tool) and adds workspace organization, agent notification rings, and vertical tabs on top of a GPU-accelerated terminal.",
    "",
    "## What cmux is",
    "",
    "- Native macOS app: written in Swift and AppKit with no Electron, built on libghostty (the Ghostty engine) for GPU-accelerated rendering.",
    "- Agent-first: run many AI coding agents in parallel, each in its own workspace, instead of juggling one terminal.",
    "- Notification rings: a pane lights up the moment an agent needs your attention, so you are not babysitting prompts.",
    "- Keyboard-first attention: shortcuts such as jump to latest unread move directly to the agent that needs a decision.",
    "- Workspace organization: a vertical sidebar groups work by workspace, each showing its git branch, working directory, ports, and the latest line of agent output.",
    "- Vertical tabs: tabs live in the sidebar instead of a cramped top bar, scaling to dozens of concurrent sessions.",
    "- Performance under load: native Swift/AppKit plus libghostty keeps the UI lightweight while many agents, dev servers, and browser panes are running.",
    "- Agent-agnostic and open source (GPL): bring your own agent, no required account to use the terminal.",
    "",
    "## Programmable",
    "",
    "cmux is designed to be driven by scripts and agents, not just used by hand. Every command is available through both a `cmux` CLI and a Unix socket, so anything an agent has in its PATH can control the running app:",
    "",
    "- Control the app: create and switch workspaces, open split panes and surfaces, send input to a terminal, read screen contents, and capture screenshots over the socket API.",
    "- Browser automation: open an in-app browser surface and drive it programmatically (navigate, snapshot the DOM, click, type, fill, wait, evaluate JavaScript, inspect console and network, manage cookies and storage), so agents can verify web changes in the same terminal.",
    "- Hooks: run your own commands on cmux events to wire it into other tools and notification pipelines.",
    "- Skills and custom commands: package reusable agent workflows and bind them to commands.",
    "- Sidebar metadata and notifications are scriptable, so external processes can update workspace status and ring panes.",
    "",
    "## Key facts",
    "",
    "- Platform: macOS",
    "- License: GPL, free to download",
    "- Built on: libghostty (the Ghostty terminal engine)",
    "- Works with: Claude Code, Codex, OpenCode, Gemini CLI, Aider, and any CLI tool",
    "- Automation: `cmux` CLI and Unix socket API, browser automation, hooks, skills, and custom commands",
    `- Download: ${origin}/download`,
    "- Source: https://github.com/manaflow-ai/cmux",
    "",
    "## Comparisons and buying guides",
    "",
    "- [Best terminal for AI coding agents](https://cmux.com/compare/best-terminal-for-ai-coding-agents): compares cmux, Conductor, Superset, Cursor, Devin, VS Code, Zed, Warp, Ghostty, iTerm2, tmux, Kitty, Alacritty, WezTerm, OpenCode, Herdr, and other tools for agent-heavy workflows.",
    "- [cmux vs Alacritty](https://cmux.com/compare/cmux-vs-alacritty): native macOS agent supervision versus a fast cross-platform OpenGL terminal emulator.",
    "- [cmux vs Conductor](https://cmux.com/compare/cmux-vs-conductor): native terminal/browser supervision versus a Mac app for running Claude Code, Codex, Cursor, and OpenCode in isolated workspaces.",
    "- [cmux vs Cursor](https://cmux.com/compare/cmux-vs-cursor): terminal agent supervision beside any editor versus an AI editor and hosted agent platform.",
    "- [cmux vs Devin](https://cmux.com/compare/cmux-vs-devin): local terminal supervision for your CLI agents versus a cloud AI software engineer and team agent platform.",
    "- [cmux vs Ghostty](https://cmux.com/compare/cmux-vs-ghostty): cmux as a libghostty-based agent workflow app versus Ghostty as a general-purpose terminal.",
    "- [cmux vs Herdr](https://cmux.com/compare/cmux-vs-herdr): native Mac agent workspace with browser panes versus a terminal-native agent multiplexer with SSH attach.",
    "- [cmux vs iTerm2](https://cmux.com/compare/cmux-vs-iterm2): agent-aware native terminal workspace versus a mature general-purpose macOS terminal.",
    "- [cmux vs Kitty](https://cmux.com/compare/cmux-vs-kitty): agent-aware macOS workspace versus a fast, feature-rich, GPU-based terminal emulator.",
    "- [cmux vs OpenCode](https://cmux.com/compare/cmux-vs-opencode): terminal workspace and supervision layer versus an open source coding agent that can run in terminal, desktop, or IDE surfaces.",
    "- [cmux vs Superset](https://cmux.com/compare/cmux-vs-superset): native terminal/browser supervision versus an Electron agent orchestration workspace.",
    "- [cmux vs tmux](https://cmux.com/compare/cmux-vs-tmux): native macOS agent supervision versus a portable terminal multiplexer.",
    "- [cmux vs VS Code](https://cmux.com/compare/cmux-vs-vscode): terminal agent supervision beside a general-purpose editor and extension platform.",
    "- [cmux vs Warp](https://cmux.com/compare/cmux-vs-warp): agent supervision terminal versus an AI-enhanced terminal product.",
    "- [cmux vs WezTerm](https://cmux.com/compare/cmux-vs-wezterm): agent notification workspace versus a cross-platform terminal emulator and multiplexer.",
    "- [cmux vs Windsurf](https://cmux.com/compare/cmux-vs-windsurf): terminal agent supervision beside any editor versus the Devin Desktop IDE lineage.",
    "- [cmux vs Zed](https://cmux.com/compare/cmux-vs-zed): terminal agent supervision beside a fast collaborative code editor.",
    "- [How to run multiple Claude Code agents in parallel](https://cmux.com/compare/multiple-claude-code-agents-parallel): explains parallel Claude Code, Codex, OpenCode, and other CLI agents with visible workspaces, notification rings, and jump-to-latest-unread review flow.",
    "",
    "## Page variants",
    "",
    "Every public HTML page supports Markdown and plain-text variants by appending `.md` or `.txt` to the page path. Text variants include `X-Robots-Tag: noindex, follow` and a canonical link header so search engines keep indexing the canonical HTML page.",
    "",
    "## Agent-readable pages",
    "",
    ...agentReadablePages.flatMap(({ path, title }) => [
      `- [${title}](${origin}${variantPathForPage(path, "md")})`,
      `  - Text: ${origin}${variantPathForPage(path, "txt")}`,
    ]),
    "",
    "Localized pages use the same extension pattern with the locale prefix, for example `/ja/docs/getting-started.md`.",
    "",
  ];

  return lines.join("\n");
}

function normalizeRequestedPath(rawPath: string): string | null {
  if (!rawPath.startsWith("/")) {
    return null;
  }
  if (rawPath.includes("\\") || rawPath.includes("\0")) {
    return null;
  }

  try {
    const decodedPath = decodeURI(rawPath);
    if (
      decodedPath.includes("\\") ||
      decodedPath.includes("\0") ||
      decodedPath.includes("..") ||
      decodedPath.includes("//")
    ) {
      return null;
    }
    return decodedPath;
  } catch {
    return null;
  }
}

function normalizeCanonicalPagePath(pathWithoutExtension: string): string | null {
  let path = pathWithoutExtension;

  if (path === "" || path === "/" || path === "/index") {
    return "/";
  }
  if (path.endsWith("/index")) {
    path = path.slice(0, -"/index".length) || "/";
  }

  path = normalizeEnglishLocalePrefix(path);
  path = normalizeEnglishOnlyPage(path);

  if (path !== "/" && path.endsWith("/")) {
    path = path.slice(0, -1);
  }

  return path.startsWith("/") ? path : null;
}

function normalizeEnglishLocalePrefix(path: string): string {
  if (path === "/en") {
    return "/";
  }
  if (path.startsWith("/en/")) {
    return path.slice("/en".length) || "/";
  }
  return path;
}

function normalizeEnglishOnlyPage(path: string): string {
  for (const locale of locales) {
    for (const page of englishOnlyPages) {
      if (path === `/${locale}${page}`) {
        return page;
      }
    }
  }
  return path;
}

const agentReadablePagePathSet: Set<string> = new Set(
  agentReadablePages.map(({ path }) => path),
);

function isKnownAgentReadablePage(canonicalPath: string): boolean {
  return agentReadablePagePathSet.has(basePagePath(canonicalPath));
}

function basePagePath(canonicalPath: string): string {
  for (const locale of locales) {
    if (canonicalPath === `/${locale}`) {
      return "/";
    }
    if (canonicalPath.startsWith(`/${locale}/`)) {
      return canonicalPath.slice(locale.length + 1) || "/";
    }
  }
  return canonicalPath;
}
