// Invented power assertion data relative to `now`, in the proposed wire
// shapes (`power.assertion.list`, `power.assertion.watch`). Shared by the bun
// tests and `preview/build.ts`. No real users, hosts or process names.

const MIN = 60_000
const iso = (ms: number) => new Date(ms).toISOString()

export const grant = ["power:read", "power:write", "terminal:read", "mcp:expose", "actions:run"]

/** Scope table entries for the proposed ops (the preview host rejects unknown ops otherwise). */
export const proposedScopes = {
  "power.assertion.list": { scope: "power:read", class: "read" },
  "power.assertion.create": { scope: "power:write", class: "mutation" },
  "power.assertion.release": { scope: "power:write", class: "mutation" },
  "app.settings.set": { scope: "settings:write", class: "mutation" }
}

export type RawAssertion = Record<string, unknown>

export function hourAssertion(now: number, opts: { leftMin?: number; id?: string } = {}): RawAssertion {
  const left = opts.leftMin ?? 42
  return {
    assertion: opts.id ?? "pwr_01hour",
    kinds: ["display", "idle"],
    reason: "cmux Caffeinate: For 1 hour",
    created_at: iso(now - (60 - left) * MIN),
    expires_at: iso(now + left * MIN),
    until: null,
    owner: { actor: "user:local", origin: "user", app: "cmux/caffeinate" }
  }
}

export function commandAssertion(now: number, opts: { id?: string; actor?: string; origin?: string } = {}): RawAssertion {
  return {
    assertion: opts.id ?? "pwr_02build",
    kinds: ["idle"],
    reason: "cmux Caffeinate: While make · api runs",
    created_at: iso(now - 7 * MIN),
    expires_at: null,
    until: { terminal: "terminal_7", end: "command" },
    until_label: "make · api",
    owner: { actor: opts.actor ?? "user:local", origin: opts.origin ?? "user", app: "cmux/caffeinate" }
  }
}

export function stoppedAssertion(now: number): RawAssertion {
  return {
    assertion: "pwr_03open",
    kinds: ["display", "idle", "system"],
    reason: "cmux Caffeinate: Until stopped",
    created_at: iso(now - 95 * MIN),
    expires_at: null,
    until: null,
    owner: { actor: "user:local", origin: "user", app: "cmux/caffeinate" },
    inactive_kinds: ["system"]
  }
}

export function listValue(now: number, assertions: RawAssertion[], extra: Record<string, unknown> = {}) {
  return { revision: "10", available: true, power_source: "ac", assertions, limits: { max_per_app: 8, max_timed_s: 86400 }, ...extra }
}

export const terminals = [
  { id: "terminal_7", tab_id: "tab_7", tab_ids: ["tab_7"], title: "api", cols: 120, rows: 40, running: true, lifecycle: "running" },
  { id: "terminal_8", tab_id: "tab_8", tab_ids: ["tab_8"], title: "web", cols: 120, rows: 40, running: true, lifecycle: "running" },
  { id: "terminal_9", tab_id: "tab_9", tab_ids: ["tab_9"], title: "notes", cols: 120, rows: 40, running: true, lifecycle: "running" }
]

/** terminal.process.get per terminal: two run a command, one sits at the shell prompt. */
export const processes: Record<string, unknown> = {
  terminal_7: { pid: 4100, argv: ["-zsh"], foreground_cwd: "/work/api", foreground_executable: "/usr/bin/make", children: [4101] },
  terminal_8: { pid: 4200, argv: ["-zsh"], foreground_cwd: "/work/web", foreground_executable: "/opt/tools/bin/bun", children: [4201] },
  terminal_9: { pid: 4300, argv: ["-zsh"], foreground_cwd: "/work", foreground_executable: "/bin/zsh", children: [] }
}
