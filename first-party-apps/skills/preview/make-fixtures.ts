#!/usr/bin/env bun
// Writes the preview fixtures (invented servers, skills, projects and config
// files; no real secrets). Plans are computed with the reference merge, so the
// previews show exactly what the owner would write.
// Usage: bun first-party-apps/skills/preview/make-fixtures.ts
import { writeFileSync } from "node:fs"
import { join } from "node:path"
import { agentInfo } from "../src/model/agents.ts"
import { unifiedPatch } from "../src/model/linediff.ts"
import { type McpChange, mergeMcp, previewScope } from "../src/model/mcp.ts"

const here = import.meta.dir

const scopes = {
  "skill.list": { scope: "skill:read", class: "read" },
  "mcp_server.list": { scope: "mcp_server:read", class: "read" },
  "skill.enable": { scope: "skill:write", class: "mutation" },
  "skill.disable": { scope: "skill:write", class: "mutation" },
  "skill.remove": { scope: "skill:write", class: "mutation" },
  "skill.install": { scope: "skill:write", class: "mutation" },
  "mcp_server.add": { scope: "mcp_server:write", class: "mutation" },
  "mcp_server.enable": { scope: "mcp_server:write", class: "mutation" },
  "mcp_server.disable": { scope: "mcp_server:write", class: "mutation" },
  "mcp_server.remove": { scope: "mcp_server:write", class: "mutation" },
  "diff.decide": { scope: "mcp_server:write", class: "mutation" },
  "workspace.root": { scope: "workspace:read", class: "read" },
  "ui.open": { scope: "workspace:read", class: "mutation" },
  "app.pane.open": { scope: "workspace:write", class: "mutation" }
}
const grant = ["workspace:read", "workspace:write", "skill:read", "skill:write", "mcp_server:read", "mcp_server:write"]

// Config files as they might be on disk (invented; env values are fake placeholders).
const files: Record<string, string> = {
  claude: JSON.stringify({ numStartups: 42, theme: "dark", mcpServers: { linear: { type: "http", url: "https://mcp.linear.app/mcp" } } }, null, 2) + "\n",
  codex: [
    'model = "gpt-codex"',
    'approval_policy = "on-request"',
    "",
    "[mcp_servers.linear]",
    'url = "https://mcp.linear.app/mcp"',
    "",
    "[mcp_servers.github]",
    'command = "docker"',
    'args = ["run", "-i", "--rm", "ghcr.io/github/github-mcp-server"]',
    "[mcp_servers.github.env]",
    'GITHUB_TOKEN = "fake-token-for-preview"',
    ""
  ].join("\n"),
  opencode: JSON.stringify({ $schema: "https://opencode.ai/config.json", mcp: { browser: { type: "local", command: ["npx", "-y", "@acme/browser-mcp"], enabled: false } } }, null, 2) + "\n",
  gemini: JSON.stringify({ theme: "Default", mcpServers: {} }, null, 2) + "\n"
}

function planFor(title: string, agents: string[], change: McpChange) {
  const out = agents.map((id) => {
    const agent = agentInfo(id)!
    const before = files[id]!
    const after = mergeMcp(agent, before, change)
    const label = agent.mcp.format === "json" ? `${agent.mcp.user} › ${agent.mcp.key}` : agent.mcp.user
    return { path_label: label, kind: "modify", patch: unifiedPatch(label, previewScope(agent, before), previewScope(agent, after), 2) }
  })
  return { diff: "diff_cfg01", title, files: out, requests: ["net:docs.example.com"], sandbox: "standard" }
}

const addDocs = planFor("Add docs everywhere", ["claude", "codex", "opencode", "gemini"], { op: "add", name: "docs", entry: { transport: "http", url: "https://docs.example.com/mcp", enabled: true } })
const addDocsAgain = planFor("Add docs everywhere", ["claude", "codex"], { op: "add", name: "docs", entry: { transport: "http", url: "https://docs.example.com/mcp", enabled: true } })
const offGithub = planFor("Turn off github for Codex everywhere", ["codex"], { op: "disable", name: "github" })

const root = "root_proj01"
const skill = (id: string, name: string, agent: string, scope: string, extra: Record<string, unknown>) => ({
  id,
  name,
  agent,
  scope,
  root: scope === "project" ? root : null,
  enabled: true,
  sandbox: "standard",
  requests: ["fs:read:project"],
  source: { kind: "local", label: "" },
  ...extra
})
const releaseSrc = { kind: "git", label: "acme/agent-skills/release-notes", url: "https://github.com/acme/agent-skills.git", ref: "v1.4.0" }
const skills = [
  skill("skl_01", "release-notes", "claude", "user", { description: "Drafts release notes from merged pull requests and the changelog.", source: releaseSrc, requests: ["fs:read:project", "process:execute"], path_label: "~/.claude/skills/release-notes" }),
  skill("skl_02", "release-notes", "codex", "user", { description: "Drafts release notes from merged pull requests and the changelog.", source: releaseSrc, requests: ["fs:read:project", "process:execute"], path_label: "~/.codex/skills/release-notes" }),
  skill("skl_03", "pdf-tools", "claude", "project", { description: "Reads, fills and merges PDF forms.", source: { kind: "store", label: "acme/pdf-tools" }, sandbox: "contained", path_label: ".claude/skills/pdf-tools" }),
  skill("skl_04", "db-migrations", "codex", "project", { description: "Writes and checks database migrations for this service.", enabled: false, sandbox: "none", requests: ["process:execute", "net:db.internal.example"], path_label: ".codex/skills/db-migrations" })
]
const server = (id: string, name: string, agent: string, scope: string, extra: Record<string, unknown>) => ({
  id,
  name,
  agent,
  scope,
  root: scope === "project" ? root : null,
  enabled: true,
  sandbox: "standard",
  transport: "stdio",
  env_keys: [],
  requests: [],
  source: { kind: "local", label: "" },
  ...extra
})
const servers = [
  server("mcp_01", "linear", "claude", "user", { transport: "http", url: "https://mcp.linear.app/mcp", requests: ["net:mcp.linear.app"], path_label: "~/.claude.json", source: { kind: "agent", label: "Claude Code" } }),
  server("mcp_02", "linear", "codex", "user", { transport: "http", url: "https://mcp.linear.app/mcp", requests: ["net:mcp.linear.app"], path_label: "~/.codex/config.toml" }),
  server("mcp_03", "github", "codex", "user", { command_label: "docker run -i --rm ghcr.io/github/github-mcp-server", env_keys: ["GITHUB_TOKEN"], sandbox: "none", requests: ["process:execute", "net:api.github.com"], path_label: "~/.codex/config.toml" }),
  server("mcp_04", "postgres", "claude", "project", { command_label: "npx -y @acme/postgres-mcp", env_keys: ["DATABASE_URL"], sandbox: "contained", requests: ["process:execute", "net:db.internal.example"], path_label: ".mcp.json" }),
  server("mcp_05", "browser", "opencode", "user", { command_label: "npx -y @acme/browser-mcp", enabled: false, sandbox: "none", requests: ["process:execute"], path_label: "~/.config/opencode/opencode.json" })
]

const base = {
  "workspace.list": [
    { id: "workspace_1", session_id: "session_1", name: "notes", index: 0, focused: false },
    { id: "workspace_2", session_id: "session_1", name: "api-server", index: 1, focused: true }
  ],
  "workspace.root": { root, label: "api-server" },
  "skill.list": { skills },
  "mcp_server.list": { servers },
  "mcp_server.add": addDocs,
  "mcp_server.disable": offGithub,
  "mcp_server.enable": offGithub,
  "mcp_server.remove": offGithub,
  "skill.disable": offGithub,
  "skill.enable": offGithub,
  "diff.decide": { applied: true },
  "ui.open": {},
  "app.pane.open": {}
}

function write(name: string, fixture: Record<string, unknown>) {
  writeFileSync(join(here, `${name}.json`), JSON.stringify({ grant, scopes, ...fixture }, null, 2) + "\n")
}

for (const v of ["unified", "byAgent", "byScope"]) write(v, { ops: base })
write("stale", { ops: { ...base, "mcp_server.add": { $sequence: [addDocs, addDocsAgain] }, "diff.decide": { $error: { code: "diff.stale", message: "~/.codex/config.toml changed since the preview" } } } })
write("empty", { ops: { ...base, "skill.list": { skills: [] }, "mcp_server.list": { servers: [] } } })
write("error", { ops: { ...base, "skill.list": { $error: { code: "internal", message: "The session host could not read ~/.claude.json." } }, "mcp_server.list": { $error: { code: "config.unparseable", message: "opencode.json has comments; cmux does not rewrite it." } }, "workspace.root": { $error: { code: "operation.unsupported", message: "" } } } })
write("missing", { ops: { "workspace.list": base["workspace.list"] } })
write("unparseable", { ops: { ...base, "mcp_server.add": { $error: { code: "config.unparseable", message: "opencode.json has comments" } } } })
console.log("fixtures written")
