#!/usr/bin/env bun
// Writes the preview fixtures (invented machines, projects and memory text).
// Usage: bun first-party-apps/memory/preview/make-fixtures.ts
import { writeFileSync } from "node:fs"
import { join } from "node:path"

const here = import.meta.dir
const NOW = Date.UTC(2026, 9, 2, 17, 30)
const hour = 3_600_000

const scopes = {
  "memory.roots": { scope: "memory:read", class: "read" },
  "memory.list": { scope: "memory:read", class: "read" },
  "memory.search": { scope: "memory:read", class: "read" },
  "document.open": { scope: "document:read", class: "read" },
  "document.read": { scope: "document:read", class: "read" },
  "document.edit": { scope: "document:write", class: "mutation" },
  "document.propose": { scope: "document:read", class: "mutation" },
  "fs.trash": { scope: "fs:write", class: "mutation" },
  "ui.open": { scope: "memory:read", class: "mutation" },
  "app.pane.open": { scope: "memory:read", class: "mutation" }
}
const grant = ["machine:read", "memory:read", "document:read", "document:write", "fs:write"]

const machines = [
  { id: "machine_mac01", name: "MacBook Pro", origin: "local", status: "running", connectable: true, deleted: false, recoverable: false },
  { id: "machine_srv01", name: "build-server", origin: "server", status: "running", connectable: true, deleted: false, recoverable: false }
]
const roots = {
  mac: { machine: "machine_mac01", roots: [{ root: "root_api01", kind: "project", label: "api-server", workspace: "workspace_2" }, { root: "root_home01", kind: "user", label: "Home" }] },
  srv: { machine: "machine_srv01", roots: [{ root: "root_srvhome", kind: "user", label: "Home" }] }
}
const file = (path: string, size: number, hoursAgo: number, extra: Record<string, unknown> = {}) => ({ path, size, modified: NOW - hoursAgo * hour, revision: `rev_${path.length}`, ...extra })
const apiFiles = { files: [file("AGENTS.md", 612, 3), file("CLAUDE.md", 340, 30), file("CLAUDE.local.md", 120, 2), file("services/billing/AGENTS.md", 210, 72), file(".cursor/rules/style.mdc", 180, 400), file("README.md", 2400, 5)] }
const slug = "-work-api-server"
const homeFiles = {
  files: [
    file(".claude/CLAUDE.md", 820, 24),
    file(`.claude/projects/${slug}/memory/MEMORY.md`, 400, 1, { project_label: "api-server" }),
    file(`.claude/projects/${slug}/memory/release-process.md`, 900, 1, { project_label: "api-server" }),
    file(".codex/AGENTS.md", 300, 200),
    file(".claude/settings.json", 500, 2)
  ]
}
const srvFiles = { files: [file(".codex/AGENTS.md", 260, 50)] }

const agentsMd = [
  "# api-server agent notes",
  "",
  "## Build",
  "- Run `make test` before every commit; the suite takes about 40 s.",
  "- Never edit files under `generated/`; run `make gen` instead.",
  "",
  "## Conventions",
  "- Errors use the `ApiError` type with a stable code.",
  "- Database access goes through `store/`, never raw SQL in handlers.",
  "- Feature flags live in `config/flags.yaml`.",
  ""
].join("\n")
const agentsMdChanged = agentsMd.replace("- Feature flags live in `config/flags.yaml`.\n", "- Feature flags live in `config/flags.yaml`.\n- Use the staging database only through the read replica.\n")
const claudeMd = "# Claude notes\n\n- Prefer small pull requests with one behavior change each.\n- Ask before running database migrations.\n"
const localMd = "- My test account is the one named Sandbox; do not use production data.\n"
const billing = "# Billing service\n\n- Money is stored in integer cents.\n- Webhook handlers must be idempotent.\n"
const style = "---\ndescription: Style\n---\n- Use early returns.\n"
const homeClaude = "# Global\n\n- Answer briefly.\n- Never commit secrets.\n"
const memIndex = "- [Release process](release-process.md): tag, changelog, deploy order\n- The staging deploy needs the VPN.\n"
const release = "# Release process\n\n- Tag from main only.\n- Update the changelog before tagging.\n- Deploy api before web.\n"
const codexHome = "- Use rg instead of grep.\n"
const allTexts = [agentsMd, claudeMd, localMd, billing, style, homeClaude, codexHome, memIndex, release, codexHome]

const base = {
  "machine.list": machines,
  "memory.roots": { $sequence: [roots.mac, roots.srv] },
  "memory.list": { $sequence: [apiFiles, homeFiles, srvFiles] },
  "document.open": { doc: "doc_01", revision: "rev_7" },
  "document.read": { text: agentsMd, revision: "rev_7" },
  "document.edit": { revision: "rev_8" },
  "document.propose": { diff: "diff_mem01" },
  "fs.trash": { trashed: ["AGENTS.md"] },
  "memory.search": { hits: [{ root: "root_api01", path: "AGENTS.md", line: 9, text: "Database access goes through `store/`, never raw SQL in handlers." }, { root: "root_home01", path: ".claude/projects/-work-api-server/memory/MEMORY.md", line: 2, text: "The staging deploy needs the VPN." }] },
  "ui.open": {},
  "app.pane.open": {}
}

function write(name: string, fixture: Record<string, unknown>) {
  writeFileSync(join(here, `${name}.json`), JSON.stringify({ grant, scopes, ...fixture }, null, 2) + "\n")
}

write("files", { ops: base })
write("split", { ops: base })
write("entries", { ops: { ...base, "document.read": { $sequence: allTexts.map((text) => ({ text, revision: "rev_7" })) } } })
write("stale", { ops: { ...base, "document.read": { $sequence: [{ text: agentsMd, revision: "rev_7" }, { text: agentsMdChanged, revision: "rev_9" }] }, "document.edit": { $sequence: [{ $error: { code: "document.stale", message: "AGENTS.md changed (rev_9)" } }, { revision: "rev_10" }] } } })
write("empty", { ops: { ...base, "memory.list": { files: [] } } })
write("error", { ops: { ...base, "memory.roots": { $error: { code: "internal", message: "The session host on this Mac did not answer." } } } })
write("missing", { ops: { "machine.list": machines } })
console.log("fixtures written")
