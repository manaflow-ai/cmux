#!/usr/bin/env bun
// Writes the preview fixtures (invented machines, versions and account labels).
// Usage: bun first-party-apps/agents/preview/make-fixtures.ts
import { writeFileSync } from "node:fs"
import { join } from "node:path"

const here = import.meta.dir
const NOW = Date.UTC(2026, 9, 2, 17, 30)

const scopes = {
  "agent_cli.list": { scope: "agent_cli:read", class: "read" },
  "agent_cli.update": { scope: "agent_cli:execute", class: "mutation" },
  "agent_cli.install": { scope: "agent_cli:execute", class: "mutation" },
  "agent_cli.sign_in": { scope: "agent_cli:execute", class: "mutation" },
  "app.pane.open": { scope: "workspace:write", class: "mutation" }
}
const grant = ["machine:read", "agent_cli:read", "agent_cli:execute", "actions:run", "workspace:write"]

const machines = [
  { id: "machine_mac01", name: "MacBook Pro", origin: "local", status: "running", connectable: true, deleted: false, recoverable: false, os: "darwin" },
  { id: "machine_srv01", name: "build-server", origin: "server", status: "running", connectable: true, deleted: false, recoverable: false, os: "linux" },
  { id: "machine_vm01", name: "team-vm", origin: "team_vm", status: "running", connectable: true, deleted: false, recoverable: false, os: "linux" }
]

const latest = (version: string) => ({ version, checked_at: NOW - 20 * 60_000 })
const acct = (account: string, label: string, plan: string | null, status: string) => ({ account, label, plan, status })
const cli = (id: string, version: string, newest: string, method: string, accounts: unknown[], extra: Record<string, unknown> = {}) => ({
  cli: id,
  installed: true,
  version,
  latest: latest(newest),
  install_method: method,
  updatable: method !== "cmux",
  accounts,
  ...extra
})

const local = [
  cli("claude", "2.1.281 (Claude Code)", "2.1.290", "native", [acct("acct_c1", "Work", "Max", "signed_in")], { path_label: "~/.local/bin/claude" }),
  cli("codex", "codex-cli 0.149.1", "0.150.0", "brew", [acct("acct_x1", "Personal", "Plus", "expired")], { path_label: "/opt/homebrew/bin/codex" }),
  cli("opencode", "1.2.3", "1.2.3", "npm", [acct("acct_o1", "Default", null, "signed_in")]),
  cli("pi", "0.9.0", "0.9.0", "npm", [acct("acct_p1", "API key", null, "signed_in")]),
  cli("chief", "0.4.0", "0.4.0", "cmux", [])
]
const server = [
  cli("claude", "2.1.290", "2.1.290", "npm", [acct("acct_c2", "Work", "Max", "signed_in")]),
  cli("codex", "0.148.0", "0.150.0", "npm", [acct("acct_x2", "Shared", "Pro", "signed_in")]),
  cli("opencode", "1.1.9", "1.2.3", "npm", [])
]
const vm = [cli("claude", "2.1.250", "3.0.0-beta.1", "native", [acct("acct_c3", "Team", "Team", "signed_in")]), cli("chief", "0.4.0", "0.4.0", "cmux", [])]

function write(name: string, fixture: Record<string, unknown>) {
  writeFileSync(join(here, `${name}.json`), JSON.stringify({ grant, scopes, ...fixture }, null, 2) + "\n")
}

// The harness answers one value per op; agent_cli.list is per machine, so the
// fixture lists the three answers in machine order (Promise.all calls them in that order).
const sequence = (...answers: unknown[]) => ({ $sequence: answers })
const started = { job: "job_01", terminal: "terminal_77" }

const full = {
  ops: {
    "machine.list": machines,
    "agent_cli.list": sequence({ machine: "machine_mac01", clis: local }, { machine: "machine_srv01", clis: server }, { machine: "machine_vm01", clis: vm }),
    "agent_cli.update": started,
    "agent_cli.install": started,
    "agent_cli.sign_in": started,
    "app.pane.open": {}
  }
}

for (const v of ["byCli", "byMachine", "matrix"]) write(v, full)

write("localOnly", { ops: { "machine.list": [machines[0]], "agent_cli.list": { machine: "machine_mac01", clis: local }, "agent_cli.update": started, "agent_cli.sign_in": started, "app.pane.open": {} } })
write("empty", { ops: { "machine.list": [machines[0]], "agent_cli.list": { machine: "machine_mac01", clis: [] }, "app.pane.open": {} } })
write("error", { ops: { "machine.list": [machines[0]], "agent_cli.list": { $error: { code: "agent_cli.detect_failed", message: "The session host on this Mac did not answer in time.", retryable: true } } } })
write("missing", { ops: { "machine.list": [machines[0]] } })
write("refused", {
  grant: ["machine:read", "agent_cli:read"],
  ops: { "machine.list": [machines[0]], "agent_cli.list": { machine: "machine_mac01", clis: local }, "agent_cli.update": { $error: { code: "scope.missing", message: "agent_cli:execute is not granted" } } }
})
console.log("fixtures written")
