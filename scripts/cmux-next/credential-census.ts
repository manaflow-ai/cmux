#!/usr/bin/env bun
/**
 * Credential census: every long-lived credential file under a machine's homes, by path and kind only.
 *
 *   bun scripts/cmux-next/credential-census.ts --root DIR [--root DIR...] [--json FILE] [--markdown FILE]
 *
 * Owner's ask (relayed): "shit like this needs to be like automatically doable/setupabble for any non-me users
 * too. like shit just works." A machine set up the product's way (machine-zero-to-agents-e2e.yml: join, a
 * short-lived GitHub token, the team's inference gateway) must hold no long-lived credential copied onto it.
 *
 * What counts (kinds): a gh login (~/.config/gh/hosts.yml with a token), a Claude login
 * (~/.claude/.credentials.json), a Codex login (~/.codex/auth.json), a private key in any file (a PEM or OpenSSH
 * "PRIVATE KEY" block: *.pem, *.key, ssh id_* and the like), gcloud credentials (~/.config/gcloud's
 * credentials.db, access_tokens.db, application_default_credentials.json, legacy_credentials/), a .netrc, a
 * .git-credentials, a docker login (~/.docker/config.json with an auth entry), and an env file (.env, *.env,
 * .env.*, .envrc) with a token-looking key that has a value.
 *
 * Allowed, because the machine made them itself: its join credential (~/.acpmux/machine-credential.json), its
 * node key (~/.acpmux/node.wg.key, only when the join's marker says the join made it), and the daemon's egress
 * proxy CA key (~/.acpmux/vault-egress/ca-key.pem, made by the daemon, never handed to agents). Anything else
 * found makes the exit status 1.
 *
 * File contents are read only to classify (at most the first 256 KiB) and never printed, stored or returned:
 * a row is {root, path, kind, allowed, why}.
 */

import { lstatSync, openSync, readSync, closeSync, readdirSync, writeFileSync } from "node:fs"
import path from "node:path"

export type Row = { root: string; path: string; kind: string; allowed: boolean; why: string }
export type Census = { roots: string[]; scannedFiles: number; truncated: boolean; rows: Row[]; foreign: number }

/** The most files one census reads before it stops and says so (a home is small; a cache is not scanned twice). */
export const MAX_FILES = 200_000
const READ_MAX = 256 * 1024
/** Directories that hold no credential worth the walk and many files. */
const SKIP_DIRS = new Set(["node_modules", ".git", ".cargo/registry", ".rustup", ".bun/install", ".npm/_cacache", "target"])

const PRIVATE_KEY = /-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----/
/** An env line whose key looks like a credential and whose value is not empty. */
const ENV_SECRET = /^[ \t]*(?:export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|PRIVATE_KEY|ACCESS_KEY|CREDENTIALS?|AUTH)[A-Za-z0-9_]*[ \t]*=[ \t]*['"]?[^\s'"#]/im

/** The kind of a home-relative path from its name alone, or null when its name says nothing. */
export function kindByName(rel: string): string | null {
  const r = rel.split(path.sep).join("/")
  const base = path.posix.basename(r)
  if (r === ".config/gh/hosts.yml") return "gh-login"
  if (r === ".claude/.credentials.json") return "claude-login"
  if (r === ".codex/auth.json") return "codex-login"
  if (base === ".netrc" || base === "_netrc") return "netrc"
  if (base === ".git-credentials") return "git-credentials"
  if (r.startsWith(".config/gcloud/")) {
    const g = r.slice(".config/gcloud/".length)
    if (["credentials.db", "access_tokens.db", "application_default_credentials.json"].includes(g)) return "gcloud-credentials"
    if (g.startsWith("legacy_credentials/")) return "gcloud-credentials"
  }
  return null
}

/** Whether a file's name makes it worth reading for a private key, an env secret or a docker login. */
export function readKind(rel: string): "key" | "env" | "docker" | null {
  const r = rel.split(path.sep).join("/")
  const base = path.posix.basename(r)
  if (r === ".docker/config.json") return "docker"
  if (base === ".env" || base === ".envrc" || base.endsWith(".env") || base.startsWith(".env.")) return "env"
  if (/\.(pem|key|p8|ppk)$/i.test(base) || /^id_[a-z0-9_-]+$/i.test(base) || r.startsWith(".ssh/") || r.includes("/.ssh/")) return "key"
  return null
}

/** The kind a file's text makes it, for a name `readKind` picked, or null when it holds no credential. */
export function kindByText(which: "key" | "env" | "docker", text: string): string | null {
  if (which === "key") {
    if (!PRIVATE_KEY.test(text)) return null
    return /OPENSSH PRIVATE KEY/.test(text) ? "ssh-private-key" : "private-key"
  }
  if (which === "env") return ENV_SECRET.test(text) ? "env-token" : null
  try {
    const auths = JSON.parse(text)?.auths
    if (auths && typeof auths === "object" && Object.values(auths).some((a: any) => a && typeof a === "object" && (a.auth || a.identitytoken))) return "docker-login"
  } catch {}
  return null
}

/** gh's hosts.yml holds a login only with a token in it (a keyring login keeps none in the file, and is still a login). */
export function ghHostsHasLogin(text: string): boolean {
  return /^\s*(?:oauth_token|user)\s*:/m.test(text)
}

/** Whether a census row is the machine's own, made on it (`siblings`: the names beside it in .acpmux). */
export function allowedOwn(rel: string, kind: string, acpmuxNames: Set<string>): string | null {
  const r = rel.split(path.sep).join("/")
  if (r === ".acpmux/machine-credential.json") return "the machine's join credential, made by its join"
  if (r === ".acpmux/node.wg.key" && acpmuxNames.has("machine-join.node-key-made.json")) return "the machine's node key, made by its join (marker present)"
  if (r === ".acpmux/vault-egress/ca-key.pem" && kind === "private-key") return "the daemon's egress proxy CA key, made on the machine"
  return null
}

function readHead(file: string): string {
  const fd = openSync(file, "r")
  try {
    const buf = Buffer.alloc(READ_MAX)
    const n = readSync(fd, buf, 0, READ_MAX, 0)
    return buf.subarray(0, n).toString("latin1")
  } finally {
    closeSync(fd)
  }
}

/** One root's rows. Symlinks are listed by name only, never followed. */
export function censusRoot(root: string, budget: { files: number; truncated: boolean }): Row[] {
  const rows: Row[] = []
  let acpmuxNames = new Set<string>()
  try {
    acpmuxNames = new Set(readdirSync(path.join(root, ".acpmux")))
  } catch {}
  const add = (rel: string, kind: string) => {
    const own = allowedOwn(rel, kind, acpmuxNames)
    rows.push({ root, path: `~/${rel.split(path.sep).join("/")}`, kind, allowed: own !== null, why: own ?? "long-lived credential not made by the machine's join" })
  }
  const walk = (dir: string, rel: string) => {
    let names: string[]
    try {
      names = readdirSync(dir).sort()
    } catch {
      return
    }
    for (const name of names) {
      if (budget.files >= MAX_FILES) {
        budget.truncated = true
        return
      }
      const full = path.join(dir, name)
      const r = rel ? `${rel}/${name}` : name
      let st
      try {
        st = lstatSync(full)
      } catch {
        continue
      }
      if (st.isDirectory()) {
        if (SKIP_DIRS.has(name) || SKIP_DIRS.has(r)) continue
        walk(full, r)
        continue
      }
      if (!st.isFile()) continue
      budget.files++
      const byName = kindByName(r)
      if (byName === "gh-login") {
        let text = ""
        try { text = readHead(full) } catch {}
        if (ghHostsHasLogin(text)) add(r, byName)
        continue
      }
      if (byName) {
        add(r, byName)
        continue
      }
      if (r === ".acpmux/machine-credential.json") {
        add(r, "join-credential")
        continue
      }
      if (r === ".acpmux/node.wg.key") {
        add(r, "node-key")
        continue
      }
      const which = readKind(r)
      if (!which || st.size === 0) continue
      let text = ""
      try { text = readHead(full) } catch { continue }
      const k = kindByText(which, text)
      if (k) add(r, k)
    }
  }
  walk(root, "")
  return rows
}

export function census(roots: string[]): Census {
  const budget = { files: 0, truncated: false }
  const rows = roots.flatMap((root) => censusRoot(root, budget))
  return { roots, scannedFiles: budget.files, truncated: budget.truncated, rows, foreign: rows.filter((r) => !r.allowed).length }
}

/** The census as a markdown table (paths and kinds only). */
export function markdown(c: Census): string {
  const lines = [
    `Credential census: ${c.rows.length} credential file(s), ${c.foreign} not made by the machine, ${c.scannedFiles} files scanned${c.truncated ? " (stopped at the file limit)" : ""}.`,
    "",
    "| path | kind | verdict | why |",
    "| --- | --- | --- | --- |",
  ]
  for (const r of c.rows) lines.push(`| \`${r.path}\` | ${r.kind} | ${r.allowed ? "allowed" : "FOREIGN"} | ${r.why} |`)
  if (c.rows.length === 0) lines.push("| (none) | | | |")
  return lines.join("\n") + "\n"
}

if (import.meta.main) {
  const argv = process.argv.slice(2)
  const roots: string[] = []
  let json: string | undefined
  let md: string | undefined
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === "--root") roots.push(argv[++i]!)
    else if (a === "--json") json = argv[++i]
    else if (a === "--markdown") md = argv[++i]
    else {
      console.error(`unknown argument: ${a}`)
      process.exit(2)
    }
  }
  if (roots.length === 0 || roots.some((r) => !r || !path.isAbsolute(r))) {
    console.error("usage: credential-census.ts --root ABSOLUTE_DIR [--root DIR...] [--json FILE] [--markdown FILE]")
    process.exit(2)
  }
  const c = census(roots)
  if (json) writeFileSync(json, JSON.stringify(c, null, 2) + "\n")
  if (md) writeFileSync(md, markdown(c))
  process.stdout.write(markdown(c))
  process.exit(c.foreign > 0 || c.truncated ? 1 : 0)
}
