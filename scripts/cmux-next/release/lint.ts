/**
 * Migration linter for both cmux-next Cloud trees (plans/cmux-next/release-rails.md).
 *
 *   bun lint.ts [--tree cmux-vm|backend]... [--base <git rev>] [--root <repo>]
 *   bun lint.ts --update-lock [--tree ...]      add new, passing files to migrations.lock.json
 *
 * A file may only expand the schema (changes the deployed code survives) unless
 * its leading comment block carries `-- contract: <reason>` (at least 10
 * characters), which a later release may apply. Refused without that header,
 * on the parsed SQL (libpg_query):
 *   DROP of anything; ALTER TABLE ... DROP COLUMN / DROP CONSTRAINT / ALTER TYPE /
 *   SET NOT NULL / DROP DEFAULT; ADD COLUMN ... NOT NULL without DEFAULT; a
 *   validated ADD CONSTRAINT (CHECK or FOREIGN KEY without NOT VALID, UNIQUE,
 *   PRIMARY KEY, EXCLUDE) on an existing table; RENAME of anything; ALTER TYPE
 *   ... RENAME VALUE; CREATE INDEX on an existing table without CONCURRENTLY,
 *   and any UNIQUE index on an existing table; UPDATE or DELETE without WHERE;
 *   TRUNCATE; DO blocks, functions and procedures (they hide statements);
 *   REVOKE; GRANT beyond role-contract.json (ALL, PUBLIC, WITH GRANT OPTION,
 *   role membership, default privileges, roles, or a grantee, privilege or
 *   schema the contract does not list); BEGIN/COMMIT (the runner owns the
 *   transaction).
 * cmux-vm files also touch only schema cmux_vm, even with a contract header
 * (cmux-old's web/ shares database cmux-prod in schema public).
 * CREATE INDEX CONCURRENTLY must be the only statement in its file (the runner
 * applies that file outside a transaction and checks the index is valid).
 *
 * Every tree also must: name files NNNN_lower_snake.sql, numbered 0001.. with no
 * gap or duplicate; list every file in migrations.lock.json with its sha256 (a
 * landed file never changes: a changed hash, a removed file or an edited lock
 * entry is refused, and with --base the files and lock of that revision are
 * compared too); number a new file above every file of --base. Files up to the
 * lock's `grandfatheredThrough` predate these rules and are hash-checked only.
 */
import { createHash } from "node:crypto"
import { execFileSync } from "node:child_process"
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { REPO_ROOT, TREE_NAMES, TREES, treeOf, type Tree, type TreeName } from "./trees.ts"

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
export interface Lock {
  readonly schema: 1
  readonly trees: Record<TreeName, TreeLock>
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

export const sha256 = (text: string) => createHash("sha256").update(text).digest("hex")

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

type Node = Record<string, any>
const kindOf = (stmt: Node) => Object.keys(stmt)[0]!
const relKey = (relation: Node | undefined) => `${relation?.schemaname ?? ""}.${relation?.relname ?? ""}`
const relName = (relation: Node | undefined) => (relation?.schemaname ? `${relation.schemaname}.${relation.relname}` : String(relation?.relname))

export interface ParsedStatement {
  readonly kind: string
  readonly node: Node
}

export const parseSql = async (sql: string): Promise<Array<ParsedStatement>> => {
  const { parse } = await import("libpg-query")
  const result = (await parse(sql)) as { stmts?: Array<{ stmt: Node }> }
  return (result.stmts ?? []).map((s) => ({ kind: kindOf(s.stmt), node: s.stmt[kindOf(s.stmt)] }))
}

const grantProblems = (b: Node, contract: TreeRoleContract): Array<string> => {
  const problems: Array<string> = []
  if (!b.is_grant) return ["REVOKE narrows what deployed code may do"]
  if (b.grant_option) problems.push("GRANT ... WITH GRANT OPTION widens beyond the role contract")
  if (b.targtype !== "ACL_TARGET_OBJECT") problems.push(`GRANT ON ALL ... IN SCHEMA widens beyond the role contract`)
  for (const g of b.grantees ?? []) {
    const spec = g.RoleSpec
    if (spec?.roletype !== "ROLESPEC_CSTRING") problems.push(`GRANT TO ${spec?.roletype === "ROLESPEC_PUBLIC" ? "PUBLIC" : spec?.roletype} widens beyond the role contract`)
    else if (!contract.grantees.includes(spec.rolename)) problems.push(`GRANT TO ${spec.rolename}: not a grantee in role-contract.json`)
  }
  const privileges: Array<string> | undefined = b.privileges?.map((p: Node) => String(p.AccessPriv?.priv_name ?? "").toUpperCase())
  if (!privileges) problems.push("GRANT ALL widens beyond the role contract")
  if (b.objtype === "OBJECT_TABLE") {
    for (const p of privileges ?? []) if (!contract.tablePrivileges.includes(p)) problems.push(`GRANT ${p} on a table: not in role-contract.json`)
    for (const o of b.objects ?? []) {
      const schema = o.RangeVar?.schemaname ?? (b.targtype === "ACL_TARGET_OBJECT" ? undefined : o.String?.sval)
      if (!schema || !contract.schemas.includes(schema)) problems.push(`GRANT on ${o.RangeVar ? relName(o.RangeVar) : o.String?.sval}: name the schema; only ${contract.schemas.join(", ")} are in role-contract.json`)
    }
  } else if (b.objtype === "OBJECT_SCHEMA") {
    for (const p of privileges ?? []) if (!contract.schemaPrivileges.includes(p)) problems.push(`GRANT ${p} on a schema: not in role-contract.json`)
    for (const o of b.objects ?? []) if (!contract.schemas.includes(o.String?.sval)) problems.push(`GRANT on schema ${o.String?.sval}: not in role-contract.json`)
  } else {
    problems.push(`GRANT on ${String(b.objtype).replace("OBJECT_", "")} is not in role-contract.json`)
  }
  return problems
}

/** Non-expand problems of one file's statements (empty: an expand file). */
export const expandProblems = (stmts: ReadonlyArray<ParsedStatement>, contract: TreeRoleContract): Array<string> => {
  const problems: Array<string> = []
  const created = new Set<string>()
  for (const { kind, node: b } of stmts) {
    switch (kind) {
      case "CreateStmt":
        created.add(relKey(b.relation))
        break
      case "DropStmt":
        problems.push(`DROP ${String(b.removeType).replace("OBJECT_", "")}`)
        break
      case "RenameStmt":
        problems.push(`RENAME (${String(b.renameType).replace("OBJECT_", "")})`)
        break
      case "AlterEnumStmt":
        if (b.oldVal !== undefined) problems.push("ALTER TYPE ... RENAME VALUE")
        break
      case "IndexStmt": {
        const existing = !created.has(relKey(b.relation))
        if (existing && b.unique) problems.push(`CREATE UNIQUE INDEX on existing table ${relName(b.relation)} can reject writes from deployed code`)
        else if (existing && !b.concurrent) problems.push(`CREATE INDEX on existing table ${relName(b.relation)} without CONCURRENTLY locks writes`)
        break
      }
      case "AlterTableStmt": {
        const existing = !created.has(relKey(b.relation))
        if (b.objtype && b.objtype !== "OBJECT_TABLE") {
          problems.push(`ALTER ${String(b.objtype).replace("OBJECT_", "")}`)
          break
        }
        for (const c of b.cmds ?? []) {
          const cmd = c.AlterTableCmd ?? {}
          switch (cmd.subtype) {
            case "AT_DropColumn":
              problems.push(`DROP COLUMN ${cmd.name}`)
              break
            case "AT_DropConstraint":
              problems.push(`DROP CONSTRAINT ${cmd.name}`)
              break
            case "AT_AlterColumnType":
              problems.push(`ALTER COLUMN ${cmd.name} TYPE (a type change can narrow)`)
              break
            case "AT_SetNotNull":
              problems.push(`ALTER COLUMN ${cmd.name} SET NOT NULL`)
              break
            case "AT_ColumnDefault":
              if (cmd.def === undefined) problems.push(`ALTER COLUMN ${cmd.name} DROP DEFAULT`)
              break
            case "AT_AddColumn": {
              const types = new Set((cmd.def?.ColumnDef?.constraints ?? []).map((x: Node) => x.Constraint?.contype))
              if (existing && (types.has("CONSTR_NOTNULL") || types.has("CONSTR_PRIMARY")) && !types.has("CONSTR_DEFAULT")) problems.push(`ADD COLUMN ${cmd.def?.ColumnDef?.colname} NOT NULL without DEFAULT`)
              if (existing && (types.has("CONSTR_UNIQUE") || types.has("CONSTR_PRIMARY"))) problems.push(`ADD COLUMN ${cmd.def?.ColumnDef?.colname} UNIQUE/PRIMARY KEY on an existing table`)
              break
            }
            case "AT_AddConstraint": {
              const con = cmd.def?.Constraint ?? {}
              const notValid = con.skip_validation === true && (con.contype === "CONSTR_CHECK" || con.contype === "CONSTR_FOREIGN")
              if (existing && !notValid) problems.push(`ADD CONSTRAINT ${con.conname ?? ""} validated on an existing table (use CHECK or FOREIGN KEY ... NOT VALID)`.replace("  ", " "))
              break
            }
            default:
              break
          }
        }
        break
      }
      case "UpdateStmt":
        if (!b.whereClause) problems.push(`UPDATE ${relName(b.relation)} without WHERE`)
        break
      case "DeleteStmt":
        if (!b.whereClause) problems.push(`DELETE FROM ${relName(b.relation)} without WHERE`)
        break
      case "TruncateStmt":
        problems.push("TRUNCATE")
        break
      case "DoStmt":
      case "CreateFunctionStmt":
        problems.push(`${kind === "DoStmt" ? "DO block" : "CREATE FUNCTION/PROCEDURE"} (the statements inside are not checked)`)
        break
      case "GrantStmt":
        problems.push(...grantProblems(b, contract))
        break
      case "GrantRoleStmt":
        problems.push("GRANT <role> TO ... (role membership) widens beyond the role contract")
        break
      case "AlterDefaultPrivilegesStmt":
        problems.push("ALTER DEFAULT PRIVILEGES widens beyond the role contract")
        break
      case "CreateRoleStmt":
      case "AlterRoleStmt":
      case "DropRoleStmt":
        problems.push(`${kind.replace("Stmt", "")}: roles are managed with pscale, not migrations`)
        break
      default:
        break
    }
  }
  return problems
}

/**
 * cmux-vm only: every object a statement names is in schema `schema`. cmux-old
 * (web/, schema public) shares the cmux-prod database, so this holds even with
 * a contract header. Refused: a relation outside the schema or unqualified
 * (search_path would pick public), a qualified type or function of another
 * schema (pg_catalog is allowed), another schema's CREATE/DROP/GRANT, and SET.
 */
export const confinementProblems = (stmts: ReadonlyArray<ParsedStatement>, schema: string): Array<string> => {
  const problems = new Set<string>()
  const allowed = new Set([schema, "pg_catalog"])
  const firstName = (list: unknown): string | undefined => (Array.isArray(list) && list.length >= 2 ? (list[0] as Node)?.String?.sval : undefined)
  const visit = (node: unknown, key?: string): void => {
    if (Array.isArray(node)) {
      if (key === "names" || key === "funcname" || key === "typeName") {
        const first = firstName(node)
        if (first !== undefined && !allowed.has(first)) problems.add(`${node.map((n: Node) => n.String?.sval).join(".")} is in schema ${first}`)
      }
      for (const item of node) visit(item)
      return
    }
    if (!node || typeof node !== "object") return
    for (const [k, v] of Object.entries(node as Node)) {
      if ((k === "relation" || k === "pktable" || k === "RangeVar") && v && typeof v === "object" && "relname" in v) {
        if ((v as Node).schemaname !== schema) problems.add(`${relName(v as Node)} is ${(v as Node).schemaname ? `in schema ${(v as Node).schemaname}` : "unqualified (name it " + schema + "." + (v as Node).relname + ")"}`)
      }
      if (k === "CreateSchemaStmt" && (v as Node).schemaname !== schema) problems.add(`CREATE SCHEMA ${(v as Node).schemaname}`)
      if (k === "VariableSetStmt") problems.add(`SET ${(v as Node).name ?? ""}`.trim())
      if (k === "DropStmt") {
        for (const o of ((v as Node).objects ?? []) as Array<Node>) {
          const items = (o.List?.items ?? (o.String ? [o] : [])) as Array<Node>
          const names = items.map((i) => i.String?.sval)
          if ((v as Node).removeType === "OBJECT_SCHEMA") {
            if (names[0] !== schema) problems.add(`DROP SCHEMA ${names[0]}`)
          } else if (names.length < 2) problems.add(`DROP of unqualified ${names.join(".")}`)
          else if (!allowed.has(names[0]!)) problems.add(`DROP of ${names.join(".")}`)
        }
      }
      if (k === "GrantStmt" && (v as Node).objtype === "OBJECT_SCHEMA") {
        for (const o of ((v as Node).objects ?? []) as Array<Node>) if (o.String?.sval !== schema) problems.add(`GRANT on schema ${o.String?.sval}`)
      }
      visit(v, k)
    }
  }
  for (const s of stmts) visit({ [s.kind]: s.node })
  return [...problems]
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
  const concurrent = stmts.some((s) => s.kind === "IndexStmt" && s.node.concurrent === true)
  if (concurrent && stmts.length !== 1) errors.push(`${name}: CREATE INDEX CONCURRENTLY must be the only statement in its file (it runs outside a transaction)`)
  if (tree.name === "cmux-vm") {
    for (const problem of confinementProblems(stmts, tree.schema)) errors.push(`${name}: ${problem}; cmux-vm migrations touch only schema ${tree.schema} (cmux-old shares this database), even with a contract header`)
  }
  if (reason === undefined) {
    for (const problem of expandProblems(stmts, contract)) errors.push(`${name}: ${problem}; this is a contract change: add "-- contract: <reason>" and ship it in a later release`)
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

export interface LintOptions {
  readonly root: string
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

  // Against the base revision: its files and lock entries are unchanged, new files number above it.
  if (options.base) {
    const baseFiles = gitList(options.root, options.base, tree.dir)
    let baseMax = 0
    for (const name of baseFiles) {
      baseMax = Math.max(baseMax, Number(name.slice(0, 4)) || 0)
      const baseSql = gitShow(options.root, options.base, `${tree.dir}/${name}`)
      const f = present.get(name)
      if (!f) errors.push(`${tree.name}: ${name} exists at ${options.base.slice(0, 12)} and is gone; a landed migration is never removed or renamed`)
      else if (baseSql !== undefined && sha256(baseSql) !== f.checksum) errors.push(`${tree.name}: ${name} differs from ${options.base.slice(0, 12)}; a landed migration never changes`)
    }
    for (const f of files) if (!baseFiles.includes(f.name) && f.number <= baseMax) errors.push(`${tree.name}: new ${f.name} must be numbered above ${String(baseMax).padStart(4, "0")} (the base's highest)`)
    const baseLockText = gitShow(options.root, options.base, LOCK_PATH)
    if (baseLockText) {
      const baseLock = (JSON.parse(baseLockText) as Lock).trees[tree.name]
      for (const [name, hash] of Object.entries(baseLock?.files ?? {})) {
        if (lock.files[name] !== hash) errors.push(`${tree.name}: lock entry ${name} differs from ${options.base.slice(0, 12)}; lock entries are append-only`)
      }
      if (baseLock && baseLock.grandfatheredThrough !== lock.grandfatheredThrough) errors.push(`${tree.name}: grandfatheredThrough moved from ${baseLock.grandfatheredThrough} to ${lock.grandfatheredThrough}; it never moves`)
    }
  }

  // Rules for every file after the grandfathered ones.
  if (contract) {
    for (const f of files) {
      if (f.name.slice(0, 4) <= lock.grandfatheredThrough && f.name in lock.files) continue
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
  const next: Lock = { schema: 1, trees: { ...options.lock.trees } }
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
