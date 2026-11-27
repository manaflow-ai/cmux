#!/usr/bin/env bun
// Writes the preview fixtures (invented data; no real hosts, paths or people).
// Usage: bun first-party-apps/finder/preview/make-fixtures.ts
import { writeFileSync } from "node:fs"
import { join } from "node:path"

const here = import.meta.dir
const NOW = Date.UTC(2026, 9, 2, 17, 30)
const day = 86_400_000

const scopes = {
  "host.list": { scope: "host:read", class: "read" },
  "host.connect": { scope: "host:control", class: "mutation" },
  "host.disconnect": { scope: "host:control", class: "mutation" },
  "fs.roots.list": { scope: "fs:read", class: "read" },
  "fs.root.pick": { scope: "fs:read", class: "mutation" },
  "fs.list": { scope: "fs:read", class: "read" },
  "fs.read": { scope: "fs:read", class: "read" },
  "fs.thumbnail": { scope: "fs:read", class: "read" },
  "fs.mkdir": { scope: "fs:write", class: "mutation" },
  "fs.rename": { scope: "fs:write", class: "mutation" },
  "fs.copy": { scope: "fs:write", class: "mutation" },
  "fs.move": { scope: "fs:write", class: "mutation" },
  "fs.trash": { scope: "fs:write", class: "mutation" },
  "fs.job.list": { scope: "fs:read", class: "read" },
  "fs.job.cancel": { scope: "fs:write", class: "mutation" },
  "fs.job.resolve": { scope: "fs:write", class: "mutation" },
  "fs.undo": { scope: "fs:write", class: "mutation" },
  "document.open": { scope: "fs:read", class: "mutation" },
  "app.pane.open": { scope: "fs:read", class: "mutation" }
}

const conns = [
  { conn: "conn_local01", host: "host_mac01", kind: "local", label: "This Mac", state: "connected", path: null },
  { conn: "conn_srv01", host: "host_studio01", kind: "server", label: "studio", state: "connected", path: "direct · 3 ms" },
  { conn: "conn_team01", host: "host_teamvm01", kind: "team_vm", label: "acme team VM", state: "connected", path: "tunnel · 9 ms" },
  { conn: "conn_ssh01", host: null, kind: "ssh", label: "build-box", state: "disconnected", path: null }
]

const roots = [
  { root: "root_home01", conn: "conn_local01", label: "Home", kind: "home", display: "~", rights: "read_write" },
  { root: "root_proj01", conn: "conn_local01", label: "orbit", kind: "workspace", display: "~/src/orbit", rights: "read_write" },
  { root: "root_dl01", conn: "conn_local01", label: "Downloads", kind: "folder", display: "~/Downloads", rights: "read_write" },
  { root: "root_team01", conn: "conn_team01", label: "acme", kind: "remote", display: "acme:/home/dev", rights: "read_write" },
  { root: "root_srv01", conn: "conn_srv01", label: "studio", kind: "remote", display: "studio:~", rights: "read" }
]

const dir = (name: string, ago: number, hidden = false) => ({ name, kind: "dir", size: null, mtime: NOW - ago * day, ...(hidden ? { hidden: true } : {}) })
const file = (name: string, size: number, ago: number) => ({ name, kind: "file", size, mtime: NOW - ago * day })

const homeEntries = [
  dir("Desktop", 1),
  dir("Documents", 3),
  dir("Downloads", 0.1),
  dir("src", 0.02),
  dir(".config", 9, true),
  file("notes.md", 2_140, 0.05),
  file("deploy-checklist.md", 5_300, 2),
  file("screenshot-2026-09-30.png", 1_840_000, 2),
  file("design-review.pdf", 4_120_000, 6),
  file("build.log", 182_000, 0.3),
  file("backup-2026-09.tar.gz", 1_240_000_000, 12),
  file("todo.txt", 640, 1)
]

const srcEntries = [dir("orbit", 0.02), dir("orbit-web", 4), dir("scratch", 20), file("README.md", 900, 30)]
const orbitEntries = [dir(".github", 30), dir("docs", 2), dir("scripts", 5), dir("Sources", 0.02), dir("Tests", 1), file("Package.swift", 3_400, 3), file("README.md", 6_200, 2), file("LICENSE", 1_070, 200)]
const teamEntries = [dir("deploy", 1), dir("datasets", 7), dir("logs", 0.01), file("compose.yaml", 2_900, 4), file("Makefile", 1_400, 9), file("seed.sql", 88_000_000, 15)]

const batch = (entries: Array<{ hidden?: boolean }>, listing: string, extra: Record<string, unknown> = {}) => ({ listing, entries, cursor: null, total: entries.filter((e) => !e.hidden).length, revision: "1042", ...extra })

const notes = `# Release notes draft

Shipping the file browser prototype this week.

## Done
- Column view and dual pane
- Copy between hosts with progress
- Previews for text, images and PDF

## Next
- Keyboard selection in lists
- Drag onto terminals and agents
`

const base = {
  scopes,
  ops: {
    "host.list": { conns },
    "fs.roots.list": { roots },
    "fs.job.list": { jobs: [] },
    "app.storage.get": [
      { conn: "conn_local01", root: "root_proj01", path: "Sources", label: "Sources" },
      { conn: "conn_team01", root: "root_team01", path: "logs", label: "logs" }
    ],
    "fs.list": batch(homeEntries, "lst_home01"),
    "fs.read": { text: notes, truncated: false, size: 2140, encoding: "utf8" },
    "fs.thumbnail": { image: "img_shot01", width: 2880, height: 1800 }
  } as Record<string, unknown>,
  events: [] as unknown[]
}

const write = (name: string, value: unknown) => writeFileSync(join(here, `${name}.json`), `${JSON.stringify(value, null, 2)}\n`)
const withOps = (ops: Record<string, unknown>, events: unknown[] = []) => ({ ...base, ops: { ...base.ops, ...ops }, events })

write("listPreview", base)
write("columns", withOps({ "fs.list": { $sequence: [batch(homeEntries, "lst_home01"), batch(srcEntries, "lst_src01"), batch(orbitEntries, "lst_orbit01")] } }))
write("dualPane", withOps({ "fs.list": { $sequence: [batch(homeEntries, "lst_home01"), batch(teamEntries, "lst_team01")] } }))
write("empty", withOps({ "fs.list": batch([], "lst_empty01") }))
write("error", withOps({ "fs.list": { $error: { code: "fs.permission_denied", message: "The owner refused to list this folder (permission denied).", retryable: false } } }))
write("missing", { ops: {} })

const connecting = conns.map((c) => (c.conn === "conn_ssh01" ? { ...c, state: "connecting", detail: "Opening an SSH session through cmux link" } : c))
write(
  "connecting",
  withOps({
    "host.list": { conns: connecting },
    "fs.roots.list": { roots: [{ root: "root_ssh01", conn: "conn_ssh01", label: "build-box", kind: "home", display: "build-box:~", rights: "read_write" }, ...roots.slice(1)] }
  })
)

const big = Array.from({ length: 200 }, (_, i) => file(`trace-${String(i + 1).padStart(6, "0")}.log`, 40_000 + ((i * 7919) % 90_000), 0.5 + i / 400))
write("large", withOps({ "fs.list": batch(big, "lst_big01", { cursor: "cur_0200", total: 100_000 }) }))

const running = {
  job: "job_copy01",
  op: "copy",
  phase: "running",
  seq: 41,
  subject: "3 items",
  destination: "acme team VM",
  cross_host: true,
  bytes_done: 1_260_000_000,
  bytes_total: 4_020_000_000,
  items_done: 1,
  items_total: 3,
  current: "backup-2026-09.tar.gz",
  eta_s: 214,
  conflict: null,
  undo: null,
  started_at: NOW - 90_000
}
const conflict = {
  ...running,
  job: "job_copy02",
  phase: "conflict",
  seq: 12,
  subject: "deploy-checklist.md",
  destination: "studio",
  bytes_done: 0,
  bytes_total: 5_300,
  items_done: 0,
  items_total: 1,
  eta_s: null,
  conflict: { item: "deploy-checklist.md", existing: { size: 4_900, mtime: NOW - 3 * day }, incoming: { size: 5_300, mtime: NOW - 2 * day } }
}
write("copy", withOps({ "fs.job.list": { jobs: [running, conflict] }, "fs.list": { $sequence: [batch(homeEntries, "lst_home01"), batch(teamEntries, "lst_team01")] } }, [{ afterMs: 300, stream: "fs.job", payload: { job: "job_copy01", event: { kind: "progress", seq: 42, bytes_done: 1_480_000_000, items_done: 1, eta_s: 190 } } }]))
console.log("fixtures written")
