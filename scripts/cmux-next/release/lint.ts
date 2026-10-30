/**
 * Migration linter for both cmux-next Cloud trees (plans/cmux-next/release-rails.md).
 *
 *   bun lint.ts [--tree cmux-vm|backend]... [--base <git rev>] [--root <repo>]
 *   bun lint.ts --update-lock [--tree ...]      add new, passing files to migrations.lock.json
 *
 * Statement rules (lint-rules.ts): a strict allowlist of exact expand shapes; a
 * `-- contract: <reason>` header (10+ characters, leading comment block) lifts only a named list
 * of non-expand operations; everything else is refused always. cmux-vm names stay in schema
 * cmux_vm (cmux-old shares cmux-prod). CREATE/DROP INDEX CONCURRENTLY is alone in its file.
 *
 * Tree rules: NNNN_lower_snake.sql numbered 0001.. without gaps; every file in
 * migrations.lock.json with its sha256 (a landed file never changes or disappears, lock entries
 * are append-only, and with --base that revision's files and lock are compared and new files
 * number above it; a --base that does not resolve fails); cmux-vm REQUIRED_SCHEMA names the
 * newest file; the installed libpg-query matches the pinned version and hashes. Only the files in
 * GRANDFATHERED (exact name and hash) skip the statement rules.
 */
import { createHash } from "node:crypto"
import { execFileSync, spawnSync } from "node:child_process"
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join, relative } from "node:path"
import { REPO_ROOT, TREE_NAMES, TREES, treeOf, type Tree, type TreeName } from "./trees.ts"
import { confinementProblems, parseSql, statementProblems, type ParsedStatement } from "./lint-rules.ts"
export { confinementProblems, parseSql, statementProblems, type ParsedStatement } from "./lint-rules.ts"

/**
 * Files that predate the rules (P2-3): exempt from the statement rules only by exact name AND
 * hash, fixed here in the linter so no lock edit or intermediate push can move the boundary.
 */
export const GRANDFATHERED: Readonly<Record<TreeName, Readonly<Record<string, string>>>> = {
  "cmux-vm": {
    "0001_cmux_vm_ownership.sql": "efaa9268d47ee6bfbf3ab6e596c982c4f9b6f870c9cec78c7433eb3abc2bd9ee",
    "0002_cmux_vm_display_name_audit.sql": "61d4d0089eb559be47943c5549fa7958a0aa0d3ca5ed8a9eb178a915a65b7451",
    "0003_cmux_vm_snapshot_parent.sql": "cadb388568905531912fdc73080246074b65b7c1f09121b70ba936f5b9a28053",
    "0004_cmux_vm_mesh.sql": "b5fc967440bc82ac34c97cda0be3e99609b0537e8094814820b666afa2bd219e",
    "0005_cmux_vm_mesh_m2.sql": "12a58159148dc116cdf55a1d087dff2d5437b7185257ccef996a67e99c523b75",
    "0006_cmux_vm_mesh_m3.sql": "7657e3f456366ceb8423eaec40810f2024359a9b2a67130e82b773178f2621ee",
    "0007_cmux_vm_mesh_m4.sql": "a3525bda461b9c19f2cdf74ff3a457e90ace177b7b517e187ea5b1173b734fe7",
    "0008_cmux_vm_mesh_m4_retries.sql": "023cbec42e3137e7c506021abfcd97d6480e30c35a994a4d044c1e4fbacf90c8",
  },
  "backend": {
    "0001_init.sql": "93519f97b4a6296e55da59327368c97c721d9a9eb5e568f323d202ad4a2a16fa",
    "0002_comment_projection_tables.sql": "6ff36cfc138278f903d505dad7f65b437516037b3b895309ff9526bb40ea0fbf",
    "0003_automations.sql": "0a210f8ec4171fb820311e4be8b9739c886bdf3a07220cfc1b5fdc428aaf192a",
    "0004_connections.sql": "9459fb9706ccd0907aa46e07c8a4eb6457b363c0f1a825cc6b9c089beefa0b4c",
    "0005_audit_events.sql": "6414026f95b4a0496c02bd20e554b3954a0515460b2a4f464798ff8c8b38964c",
    "0006_home.sql": "faa8bb121be718eab407dc687836f121e679312f9f5cafc3f9e37226536ad858",
  },
}

export const LOCK_PATH = "scripts/cmux-next/release/migrations.lock.json"
export const CONTRACT_PATH = "scripts/cmux-next/release/role-contract.json"
const NAME = /^(\d{4})_[a-z0-9_]+\.sql$/
const CONTRACT_HEADER = /^--\s*contract:\s*(.*\S)\s*$/
const MIN_REASON = 10

export interface MigrationFile {
  readonly name: string
  readonly number: number
  readonly sql: string
  readonly checksum: string
}

export interface TreeLock {
  readonly grandfatheredThrough: string
  readonly files: Record<string, string>
}
export interface ParserPin {
  readonly version: string
  /** sha256 of each runtime file of node_modules/libpg-query, by path inside the package. */
  readonly sha256: Record<string, string>
}
export interface Lock {
  readonly schema: 1
  /** The SQL parser the rules depend on; a different install refuses to lint. */
  readonly parser?: ParserPin & { readonly package: string }
  /** One digest over every file of the runtime packages (the pg and libpg-query closures). */
  readonly runtime?: RuntimePin
  readonly trees: Record<TreeName, TreeLock>
}

const PARSER_DIR = join(import.meta.dirname, "node_modules", "libpg-query")

export interface RuntimePin {
  readonly packages: ReadonlyArray<string>
  readonly sha256: string
}

/** sha256 over the sorted `path:sha256` lines of every regular file of `packages` under node_modules. */
export const runtimeDigest = (packages: ReadonlyArray<string>): string => {
  const modules = join(import.meta.dirname, "node_modules")
  const lines: Array<string> = []
  const walk = (dir: string) => {
    if (!existsSync(dir)) return
    for (const e of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, e.name)
      if (e.isDirectory()) walk(path)
      else if (e.isFile()) lines.push(`${relative(modules, path)}:${sha256(readFileSync(path))}`)
    }
  }
  for (const p of packages) walk(join(modules, p))
  return sha256(lines.sort().join("\n"))
}

/** Problems with the installed runtime packages against `pin` (default: this checkout's lock). */
export const runtimeProblems = (pin: RuntimePin | undefined = readJson<Lock>(join(import.meta.dirname, "migrations.lock.json")).runtime): Array<string> => {
  if (!pin) return ["migrations.lock.json has no runtime pin"]
  const got = runtimeDigest(pin.packages)
  return got === pin.sha256 ? [] : [`the runtime packages (${pin.packages.join(", ")}) digest ${got.slice(0, 12)} is not the pinned ${pin.sha256.slice(0, 12)}`]
}

/** Problems with the installed libpg-query against `pin` (default: this checkout's lock). */
export const parserProblems = (pin: ParserPin | undefined = (readJson<Lock>(join(import.meta.dirname, "migrations.lock.json")).parser)): Array<string> => {
  if (!pin) return ["migrations.lock.json has no parser pin"]
  const problems: Array<string> = []
  const pkg = join(PARSER_DIR, "package.json")
  const version = existsSync(pkg) ? (JSON.parse(readFileSync(pkg, "utf8")) as { version?: string }).version : undefined
  if (version !== pin.version) problems.push(`libpg-query ${version ?? "missing"} is installed, the lock pins ${pin.version}`)
  for (const [file, hash] of Object.entries(pin.sha256)) {
    const path = join(PARSER_DIR, file)
    const got = existsSync(path) ? sha256(readFileSync(path)) : "missing"
    if (got !== hash) problems.push(`libpg-query ${file} sha256 ${got.slice(0, 12)} is not the pinned ${hash.slice(0, 12)}`)
  }
  return problems
}

export interface TreeRoleContract {
  /** Roles a migration may grant to (stable group roles; PlanetScale per-branch user names never belong here). */
  readonly grantees: ReadonlyArray<string>
  /** Table privileges a migration may grant. */
  readonly tablePrivileges: ReadonlyArray<string>
  /** Schemas whose objects a migration may grant on. */
  readonly schemas: ReadonlyArray<string>
  /** Schema privileges a migration may grant. */
  readonly schemaPrivileges: ReadonlyArray<string>
}
export interface RoleContract {
  readonly schema: 1
  readonly trees: Record<TreeName, TreeRoleContract>
}

export const sha256 = (text: string | Buffer) => createHash("sha256").update(text).digest("hex")

export const readMigrations = (root: string, tree: Tree): Array<MigrationFile> => {
  const dir = join(root, tree.dir)
  if (!existsSync(dir)) return []
  return readdirSync(dir)
    .filter((f) => f.endsWith(".sql"))
    .sort()
    .map((name) => {
      const sql = readFileSync(join(dir, name), "utf8")
      return { name, number: Number(name.slice(0, 4)), sql, checksum: sha256(sql) }
    })
}

/** The comment lines before the first statement. */
const leadingComments = (sql: string): Array<string> => {
  const lines: Array<string> = []
  for (const raw of sql.split("\n")) {
    const line = raw.trim()
    if (line === "") continue
    if (!line.startsWith("--")) break
    lines.push(line)
  }
  return lines
}

/** The `-- contract: <reason>` of the leading comment block, if any (a short reason is reported by the linter). */
export const contractReason = (sql: string): string | undefined => {
  for (const line of leadingComments(sql)) {
    const match = line.match(CONTRACT_HEADER)
    if (match) return match[1]
  }
  return undefined
}

/** The comment block that starts with a `-- Rollback` line (the file's own undo steps), as plain text. */
export const rollbackSection = (sql: string): string | undefined => {
  const lines = sql.split("\n")
  const start = lines.findIndex((l) => /^--\s*Rollback\b/i.test(l.trim()))
  if (start < 0) return undefined
  const out: Array<string> = []
  for (const line of lines.slice(start)) {
    if (!line.trim().startsWith("--")) break
    out.push(line.trim().replace(/^--\s?/, ""))
  }
  return out.join("\n").trim()
}

export interface FileReport {
  readonly name: string
  readonly errors: Array<string>
  readonly contract?: string
  readonly concurrent: boolean
}

/** Rules for one file (name, header, statements); grandfathered files are not passed here. */
export const lintFile = async (tree: Tree, name: string, sql: string, contract: TreeRoleContract): Promise<FileReport> => {
  const errors: Array<string> = []
  if (!NAME.test(name)) errors.push(`${name}: name must be NNNN_lower_snake.sql`)
  const reason = contractReason(sql)
  if (reason !== undefined && reason.length < MIN_REASON) errors.push(`${name}: "-- contract:" needs a reason of at least ${MIN_REASON} characters`)
  if (tree.name === "backend") {
    // backend/db/migrate.ts reads "-- phase:"; the two headers must agree.
    const phaseContract = /^--\s*phase:\s*contract\b/m.test(sql)
    if (phaseContract !== (reason !== undefined)) errors.push(`${name}: backend files carry "-- phase: contract" together with "-- contract: <reason>", or neither`)
  }
  let stmts: Array<ParsedStatement>
  try {
    stmts = await parseSql(sql)
  } catch (e) {
    return { name, errors: [...errors, `${name}: does not parse: ${(e as Error).message}`], concurrent: false }
  }
  if (stmts.length === 0) errors.push(`${name}: no statements`)
  if (stmts.some((s) => s.kind === "TransactionStmt")) errors.push(`${name}: no BEGIN/COMMIT; the runner wraps each file in a transaction`)
  const concurrent = stmts.some((s) => (s.kind === "IndexStmt" || s.kind === "DropStmt") && s.node.concurrent === true)
  if (concurrent && stmts.length !== 1) errors.push(`${name}: CREATE/DROP INDEX CONCURRENTLY must be the only statement in its file (it runs outside a transaction)`)
  if (tree.name === "cmux-vm") {
    for (const problem of confinementProblems(stmts, tree.schema)) errors.push(`${name}: ${problem}; cmux-vm migrations touch only schema ${tree.schema} (cmux-old shares this database), even with a contract header`)
  }
  const { never, liftable } = statementProblems(stmts, tree.name, tree.schema, contract)
  for (const problem of never) errors.push(`${name}: ${problem}; never allowed in a migration, even with a contract header`)
  if (reason === undefined) {
    for (const problem of liftable) errors.push(`${name}: ${problem}; this is a contract change: add "-- contract: <reason>" and ship it in a later release`)
  }
  return { name, errors, ...(reason !== undefined ? { contract: reason } : {}), concurrent }
}

const gitShow = (root: string, rev: string, path: string): string | undefined => {
  try {
    return execFileSync("git", ["-C", root, "show", `${rev}:${path}`], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], maxBuffer: 64 << 20 })
  } catch {
    return undefined
  }
}
const gitList = (root: string, rev: string, dir: string): Array<string> => {
  try {
    return execFileSync("git", ["-C", root, "ls-tree", "--name-only", `${rev}:${dir}`], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] })
      .split("\n")
      .filter((f) => f.endsWith(".sql"))
  } catch {
    return []
  }
}

/**
 * `root`'s own workers/cmux-vm/src/db/schema-requirements.ts (it has no imports), loaded from a
 * content-addressed copy so a changed file is never served from the module cache. undefined when
 * the root has none.
 */
export const requirementsModuleAt = async (root: string): Promise<{ REQUIRED_SCHEMA: ReadonlyArray<{ table: string; column?: string; privileges?: ReadonlyArray<"SELECT" | "INSERT" | "UPDATE" | "DELETE">; migration: string }>; requiredMigration: () => string } | undefined> => {
  const path = join(root, "workers/cmux-vm/src/db/schema-requirements.ts")
  if (!existsSync(path)) return undefined
  const text = readFileSync(path, "utf8")
  const copy = join(tmpdir(), `cmux-schema-requirements-${sha256(text).slice(0, 16)}.ts`)
  if (!existsSync(copy)) writeFileSync(copy, text)
  return import(copy)
}

export const requiredMigrationAt = async (root: string): Promise<string | undefined> => (await requirementsModuleAt(root))?.requiredMigration()

export interface LintOptions {
  readonly root: string
  /** The git checkout for --base comparisons when `root` holds files exported from git (production). Default: root. */
  readonly repo?: string
  readonly lock: Lock
  readonly contract: RoleContract
  /** A git revision whose files and lock this tree must keep (for example the previous head of the pushed branch). */
  readonly base?: string
}

export interface TreeReport {
  readonly tree: TreeName
  readonly errors: Array<string>
  readonly notes: Array<string>
  readonly files: Array<MigrationFile>
}

export const lintTree = async (tree: Tree, options: LintOptions): Promise<TreeReport> => {
  const errors: Array<string> = []
  const notes: Array<string> = []
  const files = readMigrations(options.root, tree)
  const lock = options.lock.trees[tree.name] ?? { grandfatheredThrough: "0000", files: {} }
  const contract = options.contract.trees[tree.name]
  if (!contract) errors.push(`${tree.name}: no entry in role-contract.json`)

  // Numbering: 0001.. without gaps or duplicates.
  files.forEach((f, i) => {
    if (!NAME.test(f.name)) return
    if (f.number !== i + 1) errors.push(`${tree.name}: ${f.name} breaks the numbering (expected ${String(i + 1).padStart(4, "0")}); numbers are unique and have no gaps`)
  })

  // Lock: every landed file keeps its hash and stays.
  const present = new Map(files.map((f) => [f.name, f]))
  for (const [name, hash] of Object.entries(lock.files)) {
    const f = present.get(name)
    if (!f) errors.push(`${tree.name}: ${name} is in the lock but missing; a landed migration is never removed or renamed`)
    else if (f.checksum !== hash) errors.push(`${tree.name}: ${name} changed after it landed (sha256 ${f.checksum.slice(0, 12)} != lock ${hash.slice(0, 12)}); add a new migration instead`)
  }
  for (const f of files) if (!(f.name in lock.files)) errors.push(`${tree.name}: ${f.name} is not in ${LOCK_PATH}; after it passes, run: bun scripts/cmux-next/release/lint.ts --update-lock`)

  for (const p of [...parserProblems(options.lock.parser), ...runtimeProblems(options.lock.runtime)]) errors.push(`${tree.name}: ${p}; reinstall with bun install --frozen-lockfile`)

  // Against the base revision: its files and lock entries are unchanged, new files number above it.
  const repo = options.repo ?? options.root
  if (options.base && spawnSync("git", ["-C", repo, "cat-file", "-e", `${options.base}^{commit}`]).status !== 0) {
    errors.push(`${tree.name}: --base ${options.base} does not resolve to a commit; refusing to lint without it`)
  } else if (options.base) {
    const baseFiles = gitList(repo, options.base, tree.dir)
    let baseMax = 0
    for (const name of baseFiles) {
      baseMax = Math.max(baseMax, Number(name.slice(0, 4)) || 0)
      const baseSql = gitShow(repo, options.base, `${tree.dir}/${name}`)
      const f = present.get(name)
      if (!f) errors.push(`${tree.name}: ${name} exists at ${options.base.slice(0, 12)} and is gone; a landed migration is never removed or renamed`)
      else if (baseSql !== undefined && sha256(baseSql) !== f.checksum) errors.push(`${tree.name}: ${name} differs from ${options.base.slice(0, 12)}; a landed migration never changes`)
    }
    for (const f of files) if (!baseFiles.includes(f.name) && f.number <= baseMax) errors.push(`${tree.name}: new ${f.name} must be numbered above ${String(baseMax).padStart(4, "0")} (the base's highest)`)
    const baseLockText = gitShow(repo, options.base, LOCK_PATH)
    if (baseLockText) {
      const baseLock = (JSON.parse(baseLockText) as Lock).trees[tree.name]
      for (const [name, hash] of Object.entries(baseLock?.files ?? {})) {
        if (lock.files[name] !== hash) errors.push(`${tree.name}: lock entry ${name} differs from ${options.base.slice(0, 12)}; lock entries are append-only`)
      }
      if (baseLock && baseLock.grandfatheredThrough !== lock.grandfatheredThrough) errors.push(`${tree.name}: grandfatheredThrough moved from ${baseLock.grandfatheredThrough} to ${lock.grandfatheredThrough}; it never moves`)
    }
  }

  // cmux-vm: the Worker's schema check names the newest migration, so the deploy gate can tell
  // whether a database is ready for this build (requirements from this root's own module).
  if (tree.name === "cmux-vm" && files.length) {
    const required = await requiredMigrationAt(options.root)
    const newest = files.at(-1)!.name.slice(0, 4)
    if (required !== undefined && required !== newest)
      errors.push(`${tree.name}: workers/cmux-vm/src/db/schema-requirements.ts requires migration ${required} but the newest file is ${newest}; add what ${newest} creates to REQUIRED_SCHEMA (a table, column or index name)`)
  }

  // Rules for every file after the grandfathered ones.
  if (contract) {
    for (const f of files) {
      if (GRANDFATHERED[tree.name][f.name] === f.checksum) continue
      const report = await lintFile(tree, f.name, f.sql, contract)
      errors.push(...report.errors.map((e) => `${tree.name}: ${e}`))
      if (report.contract !== undefined) notes.push(`${tree.name}: ${f.name} is a contract migration: ${report.contract}`)
    }
  }
  return { tree: tree.name, errors, notes, files }
}

export const readJson = <T>(path: string): T => JSON.parse(readFileSync(path, "utf8")) as T

/** Adds files that are not in the lock yet, after they pass; never changes an existing entry. */
export const updateLock = async (trees: ReadonlyArray<Tree>, options: LintOptions): Promise<{ lock: Lock; added: Array<string>; errors: Array<string> }> => {
  const next: Lock = { schema: 1, ...(options.lock.parser ? { parser: options.lock.parser } : {}), ...(options.lock.runtime ? { runtime: options.lock.runtime } : {}), trees: { ...options.lock.trees } }
  const added: Array<string> = []
  const errors: Array<string> = []
  for (const tree of trees) {
    const report = await lintTree(tree, options)
    const blocking = report.errors.filter((e) => !e.includes(`is not in ${LOCK_PATH}`))
    if (blocking.length) {
      errors.push(...blocking)
      continue
    }
    const current = next.trees[tree.name] ?? { grandfatheredThrough: "0000", files: {} }
    const files = { ...current.files }
    for (const f of report.files) {
      if (!(f.name in files)) {
        files[f.name] = f.checksum
        added.push(`${tree.name}/${f.name}`)
      }
    }
    next.trees[tree.name] = { grandfatheredThrough: current.grandfatheredThrough, files }
  }
  return { lock: next, added, errors }
}

const main = async (argv: ReadonlyArray<string>): Promise<number> => {
  const value = (flag: string) => (argv.includes(flag) ? argv[argv.indexOf(flag) + 1] : undefined)
  const root = value("--root") ?? REPO_ROOT
  const names = argv.flatMap((a, i) => (a === "--tree" ? [argv[i + 1]] : []))
  const trees = (names.length ? names : TREE_NAMES).map((n) => treeOf(n))
  const lockPath = join(root, LOCK_PATH)
  const options: LintOptions = {
    root,
    lock: readJson<Lock>(lockPath),
    contract: readJson<RoleContract>(join(root, CONTRACT_PATH)),
    ...(value("--base") ? { base: value("--base")! } : {}),
  }
  if (argv.includes("--update-lock")) {
    const { lock, added, errors } = await updateLock(trees, options)
    for (const e of errors) console.error(`lint: ${e}`)
    if (errors.length) return 1
    writeFileSync(lockPath, `${JSON.stringify(lock, null, 2)}\n`)
    console.log(added.length ? `lock: added ${added.join(", ")}` : "lock: nothing to add")
    return 0
  }
  let failed = false
  {
    const pins = [...parserProblems(options.lock.parser), ...runtimeProblems(options.lock.runtime)]
    if (!pins.length) console.log(`pins ok: libpg-query ${options.lock.parser?.version} (${Object.keys(options.lock.parser?.sha256 ?? {}).length} files incl. package.json), runtime ${options.lock.runtime?.sha256.slice(0, 12)} over ${options.lock.runtime?.packages.length} packages`)
  }
  for (const tree of trees) {
    const report = await lintTree(tree, options)
    for (const n of report.notes) console.log(`note: ${n}`)
    for (const e of report.errors) console.error(process.env.GITHUB_ACTIONS ? `::error title=Migration lint::${e}` : `lint: ${e}`)
    if (report.errors.length) failed = true
    else console.log(`lint ok: ${tree.name} (${report.files.length} migrations)`)
  }
  return failed ? 1 : 0
}

if (import.meta.main) process.exit(await main(process.argv.slice(2)))

export { TREES }
