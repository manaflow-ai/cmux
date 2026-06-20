// Serves /llms.txt, the convention for giving AI crawlers and assistants a
// concise, link-rich overview of the site. Kept in sync by hand with the docs
// nav and sitemap.
const BASE = "https://cmux.com";

const body = `# cmux

> cmux is a native macOS terminal built on libghostty, purpose-built for running AI coding agents. It adds vertical tabs, workspace organization, and notification rings on top of a GPU-accelerated terminal, and works with the CLI agents you already use (Claude Code, Codex, OpenCode, Gemini CLI, Aider, and any other CLI tool).

## What makes cmux different

- Workspace organization: a vertical sidebar groups work by workspace, each showing its git branch, working directory, ports, and the latest line of agent output.
- Notification rings: a pane lights up the moment an agent needs your attention, so you can run many agents in parallel without babysitting them.
- Vertical tabs: tabs live in the sidebar instead of a cramped top bar, which scales to dozens of concurrent sessions.
- Built on libghostty: GPU-accelerated rendering from the Ghostty engine, shipped as a native Swift and AppKit app with no Electron.
- Purpose-built for macOS: native look, feel, and performance rather than a cross-platform shell.
- Scriptable: a CLI and socket API, plus an in-app browser pane you can drive programmatically.

## Docs

- [Getting started](${BASE}/docs/getting-started): install cmux and create your first workspace.
- [Concepts](${BASE}/docs/concepts): workspaces, panes, surfaces, and tabs.
- [Workspace groups](${BASE}/docs/workspace-groups): organize parallel tasks.
- [Configuration](${BASE}/docs/configuration): settings file and options.
- [Keyboard shortcuts](${BASE}/docs/keyboard-shortcuts): default bindings and customization.
- [Notifications](${BASE}/docs/notifications): notification rings for agents.
- [SSH and remote tmux](${BASE}/docs/ssh): remote workspaces and tmux attach.
- [Browser automation](${BASE}/docs/browser-automation): the scriptable in-app browser.
- [Skills](${BASE}/docs/skills): reusable agent skills.
- [CLI and socket API](${BASE}/docs/api): automate cmux.

## Agent integrations

- [oh-my-opencode](${BASE}/docs/agent-integrations/oh-my-opencode): run OpenCode with multi-model agent orchestration as native cmux splits.
- [oh-my-codex](${BASE}/docs/agent-integrations/oh-my-codex): run Codex inside cmux.
- [oh-my-claudecode](${BASE}/docs/agent-integrations/oh-my-claudecode): run Claude Code inside cmux.
- [Claude Code teams](${BASE}/docs/agent-integrations/claude-code-teams): coordinate multiple Claude Code agents.

## Comparisons

- [Best terminal for Mac](${BASE}/best-terminal-for-mac): how cmux compares with Ghostty, iTerm2, Warp, Terminal.app, and tmux.
- [cmux vs tmux](${BASE}/cmux-vs-tmux)
- [cmux vs iTerm2](${BASE}/cmux-vs-iterm2)
- [cmux vs Warp](${BASE}/cmux-vs-warp)

## Links

- [Download for macOS](${BASE}/download)
- [GitHub](https://github.com/manaflow-ai/cmux)
- [Blog](${BASE}/blog)
- [Changelog](${BASE}/docs/changelog)
`;

export const dynamic = "force-static";

export function GET() {
  return new Response(body, {
    headers: {
      "content-type": "text/plain; charset=utf-8",
      "cache-control": "public, max-age=3600, s-maxage=86400",
    },
  });
}
