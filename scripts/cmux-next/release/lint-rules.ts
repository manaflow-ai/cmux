/**
 * Statement rules of the migration linter (lint.ts): a STRICT allowlist of exact statement shapes
 * (plans/cmux-next/release-rails.md). Each statement is one of:
 *   allowed     an expand shape below, checked field by field (unknown fields refuse);
 *   liftable    a named non-expand operation a `-- contract: <reason>` header may allow;
 *   never       everything else, with or without a header.
 * The owner role's privileges are the hard wall (guards.ts broadPrivileges, runner.ts guard); this
 * is defense in depth. cmux-vm names must be in schema cmux_vm (cmux-old shares the database).
 */
import type { TreeRoleContract } from "./lint.ts"

export type Node = Record<string, any>
export const kindOf = (stmt: Node) => Object.keys(stmt)[0]!
export const relKey = (relation: Node | undefined) => `${relation?.schemaname ?? ""}.${relation?.relname ?? ""}`
export const relName = (relation: Node | undefined) => (relation?.schemaname ? `${relation.schemaname}.${relation.relname}` : String(relation?.relname))

export interface ParsedStatement {
  readonly kind: string
  readonly node: Node
}

export const parseSql = async (sql: string): Promise<Array<ParsedStatement>> => {
  const { parse } = await import("libpg-query")
  const result = (await parse(sql)) as { stmts?: Array<{ stmt: Node }> }
  return (result.stmts ?? []).map((s) => ({ kind: kindOf(s.stmt), node: s.stmt[kindOf(s.stmt)] }))
}

/** Pure or stable built-ins a default, check or index expression may call. */
export const ALLOWED_FUNCTIONS: ReadonlySet<string> = new Set([
  "now", "gen_random_uuid", "lower", "upper", "length", "char_length", "octet_length", "btrim", "ltrim", "rtrim",
  "substr", "left", "right", "replace", "position", "strpos", "abs", "round", "floor", "ceil", "date_trunc",
  "jsonb_typeof", "jsonb_array_length", "array_length", "cardinality", "md5", "family", "masklen",
])
const BUILTIN_TYPES: ReadonlySet<string> = new Set([
  "int2", "int4", "int8", "smallint", "integer", "int", "bigint", "smallserial", "serial", "bigserial", "serial2", "serial4", "serial8", "numeric", "decimal", "float4", "float8", "real",
  "bool", "boolean", "text", "varchar", "bpchar", "char", "bytea", "date", "time", "timetz", "timestamp", "timestamptz", "interval",
  "uuid", "json", "jsonb", "inet", "cidr", "macaddr", "tsvector",
])
const SAFE_OPS: ReadonlySet<string> = new Set(["=", "<>", "!=", "<", ">", "<=", ">=", "+", "-", "*", "/", "%", "||", "~", "~*", "!~", "!~*", "@>", "<@", "&&", "?", "#>>", "->>", "->"])
const INDEX_METHODS: ReadonlySet<string> = new Set(["btree", "gin", "gist", "hash"])

interface Ctx {
  readonly tree: string
  readonly schema: string
  readonly contract: TreeRoleContract
  readonly never: Array<string>
  readonly liftable: Array<string>
  readonly created: Set<string>
}

const names = (list: unknown): Array<string> => (Array.isArray(list) ? list.map((n: Node) => n?.String?.sval) : [])
/** A relation in the tree's schema (cmux-vm: qualified cmux_vm; backend: public or unqualified). */
const inSchema = (c: Ctx, rel: Node | undefined) => (c.tree === "cmux-vm" ? rel?.schemaname === c.schema : !rel?.schemaname || rel.schemaname === c.schema)
const keysOnly = (node: Node, allowed: ReadonlyArray<string>) => Object.keys(node).filter((k) => !allowed.includes(k) && k !== "location")

/** A type name: a built-in (bare or pg_catalog.*), or a type of the tree's schema (cmux-vm enums). */
const typeOk = (c: Ctx, t: Node | undefined): boolean => {
  if (!t) return false
  const n = names(t.names)
  if (keysOnly(t, ["names", "typmods", "typemod", "arrayBounds", "setof", "pct_type"]).length || t.setof || t.pct_type) return false
  if ((t.typmods ?? []).some((m: Node) => !m.A_Const)) return false
  if (n.length === 1) return BUILTIN_TYPES.has(n[0]!)
  if (n.length === 2) return (n[0] === "pg_catalog" && BUILTIN_TYPES.has(n[1]!)) || n[0] === c.schema
  return false
}

/** An expression of columns, constants, safe operators and allowlisted functions only. */
const exprOk = (c: Ctx, e: unknown, columns = true): boolean => {
  if (Array.isArray(e)) return e.every((x) => exprOk(c, x, columns))
  if (!e || typeof e !== "object") return true
  const n = e as Node
  const [k] = Object.keys(n)
  const v = n[k!]
  switch (k) {
    case "A_Const":
    case "SQLValueFunction":
      return true
    case "ColumnRef":
      return columns && names(v.fields).every((f) => typeof f === "string")
    case "TypeCast":
      return typeOk(c, v.typeName) && exprOk(c, v.arg, columns)
    case "A_Expr": {
      const op = names(v.name)
      if (op.length !== 1) return false // OPERATOR(schema.op)
      const opOk = ["AEXPR_OP", "AEXPR_OP_ANY", "AEXPR_OP_ALL"].includes(v.kind) ? SAFE_OPS.has(op[0]!) : ["AEXPR_IN", "AEXPR_LIKE", "AEXPR_ILIKE", "AEXPR_BETWEEN", "AEXPR_NOT_BETWEEN", "AEXPR_DISTINCT", "AEXPR_NOT_DISTINCT", "AEXPR_NULLIF"].includes(v.kind)
      return opOk && exprOk(c, v.lexpr, columns) && exprOk(c, v.rexpr, columns)
    }
    case "BoolExpr":
      return exprOk(c, v.args, columns)
    case "NullTest":
    case "BooleanTest":
      return exprOk(c, v.arg, columns)
    case "CoalesceExpr":
    case "MinMaxExpr":
      return exprOk(c, v.args, columns)
    case "A_ArrayExpr":
      return exprOk(c, v.elements, columns)
    case "List":
      return exprOk(c, v.items, columns)
    case "CaseExpr":
      return exprOk(c, v.arg, columns) && exprOk(c, v.args, columns) && exprOk(c, v.defresult, columns)
    case "CaseWhen":
      return exprOk(c, v.expr, columns) && exprOk(c, v.result, columns)
    case "FuncCall": {
      const f = names(v.funcname)
      const plain = f.length === 1 || (f.length === 2 && f[0] === "pg_catalog")
      return plain && ALLOWED_FUNCTIONS.has(f.at(-1)!) && !v.agg_filter && !v.over && !v.agg_star && !v.agg_order && exprOk(c, v.args, columns)
    }
    default:
      return false // SubLink, CollateClause, RowExpr, ParamRef, A_Indirection, ...
  }
}

/** A column or table constraint of a CREATE TABLE (or of a column added to a table created here). */
const constraintOk = (c: Ctx, con: Node, where: string): boolean => {
  const allowedKeys = ["contype", "conname", "raw_expr", "keys", "pktable", "pk_attrs", "fk_attrs", "fk_matchtype", "fk_upd_action", "fk_del_action", "skip_validation", "initially_valid", "is_enforced", "deferrable", "initdeferred", "nulls_not_distinct", "is_no_inherit"]
  const extra = keysOnly(con, allowedKeys)
  if (extra.length) return fail(c, `${where}: constraint option ${extra.join(", ")}`)
  switch (con.contype) {
    case "CONSTR_NULL":
    case "CONSTR_NOTNULL":
    case "CONSTR_PRIMARY":
    case "CONSTR_UNIQUE":
    case "CONSTR_ATTR_DEFERRABLE":
    case "CONSTR_ATTR_NOT_DEFERRABLE":
    case "CONSTR_ATTR_DEFERRED":
    case "CONSTR_ATTR_IMMEDIATE":
      return true
    case "CONSTR_DEFAULT":
      return exprOk(c, con.raw_expr, false) || fail(c, `${where}: DEFAULT must be a constant or an allowlisted function`)
    case "CONSTR_CHECK":
      return exprOk(c, con.raw_expr) || fail(c, `${where}: CHECK uses something outside columns, constants, safe operators and allowlisted functions`)
    case "CONSTR_FOREIGN":
      return inSchema(c, con.pktable) || fail(c, `${where}: REFERENCES ${relName(con.pktable)} is outside ${c.schema}`)
    default:
      return fail(c, `${where}: ${String(con.contype).replace("CONSTR_", "")} constraint`)
  }
}

const fail = (c: Ctx, why: string): false => {
  c.never.push(why)
  return false
}

const columnOk = (c: Ctx, col: Node, where: string, existing: boolean): void => {
  const extra = keysOnly(col, ["colname", "typeName", "constraints", "is_local"])
  if (extra.length) fail(c, `${where} ${col.colname}: ${extra.join(", ")} (for example COLLATE or STORAGE)`)
  if (!typeOk(c, col.typeName)) fail(c, `${where} ${col.colname}: type ${names(col.typeName?.names).join(".")} is not a built-in or ${c.schema} type`)
  const cons: Array<Node> = (col.constraints ?? []).map((x: Node) => x.Constraint ?? {})
  for (const con of cons) constraintOk(c, con, `${where} ${col.colname}`)
  if (existing) {
    // A serial column adds a sequence and a nextval() default: a rewrite of a live table (P2-2).
    if (/^(small|big)?serial[248]?$/.test(names(col.typeName?.names).at(-1) ?? "")) fail(c, `${where} ${col.colname}: a serial column on an existing table`)
    const types = new Set(cons.map((x) => x.contype))
    for (const t of types) if (!["CONSTR_NULL", "CONSTR_NOTNULL", "CONSTR_DEFAULT", "CONSTR_CHECK"].includes(t)) fail(c, `${where} ${col.colname}: ${String(t).replace("CONSTR_", "")} on an existing table`)
    if (types.has("CONSTR_CHECK")) c.liftable.push(`${where} ${col.colname}: a CHECK on a new column of an existing table scans it (validated)`)
    if (types.has("CONSTR_NOTNULL") && !types.has("CONSTR_DEFAULT")) fail(c, `${where} ${col.colname}: NOT NULL without DEFAULT on an existing table`)
    // Any function but now() (stable) in a default of an existing table may be volatile: a table rewrite.
    const calls = (e: unknown): Array<string> =>
      Array.isArray(e) ? e.flatMap(calls) : e && typeof e === "object" ? [...((e as Node).FuncCall ? [names((e as Node).FuncCall.funcname).at(-1) ?? ""] : []), ...Object.values(e as Node).flatMap(calls)] : []
    for (const d of cons.filter((x) => x.contype === "CONSTR_DEFAULT")) if (calls(d.raw_expr).some((f) => f !== "now")) fail(c, `${where} ${col.colname}: a volatile DEFAULT rewrites an existing table`)
  }
}

const createTable = (c: Ctx, b: Node) => {
  if (!inSchema(c, b.relation)) return fail(c, `CREATE TABLE ${relName(b.relation)} is outside ${c.schema}`)
  const allowed = ["relation", "tableElts", "if_not_exists", "oncommit"]
  if (c.tree === "backend") allowed.push("partspec", "partbound", "inhRelations")
  const extra = keysOnly(b, allowed)
  if (extra.length) return fail(c, `CREATE TABLE ${relName(b.relation)}: ${extra.join(", ")} (inheritance, options, tablespace, access method or partitions)`)
  if (b.relation?.relpersistence && b.relation.relpersistence !== "p") return fail(c, `CREATE TABLE ${relName(b.relation)}: only permanent tables (no TEMP or UNLOGGED)`)
  if (b.oncommit && b.oncommit !== "ONCOMMIT_NOOP") return fail(c, `CREATE TABLE ${relName(b.relation)}: ON COMMIT`)
  if (c.tree === "backend" && b.inhRelations?.length && !b.partbound) return fail(c, `CREATE TABLE ${relName(b.relation)}: INHERITS`)
  // IF NOT EXISTS may meet a live table: it never counts as created here (P2-1).
  if (!b.if_not_exists) c.created.add(relKey(b.relation))
  for (const el of b.tableElts ?? []) {
    if (el.ColumnDef) columnOk(c, el.ColumnDef, `CREATE TABLE ${relName(b.relation)}`, false)
    else if (el.Constraint) constraintOk(c, el.Constraint, `CREATE TABLE ${relName(b.relation)}`)
    else fail(c, `CREATE TABLE ${relName(b.relation)}: ${Object.keys(el)[0]} element (for example LIKE)`)
  }
}

const createIndex = (c: Ctx, b: Node) => {
  const where = `CREATE INDEX ${b.idxname ?? ""} ON ${relName(b.relation)}`
  if (!inSchema(c, b.relation)) return fail(c, `${where}: outside ${c.schema}`)
  const extra = keysOnly(b, ["idxname", "relation", "accessMethod", "indexParams", "indexIncludingParams", "whereClause", "unique", "nulls_not_distinct", "concurrent", "if_not_exists", "primary"])
  if (extra.length) return fail(c, `${where}: ${extra.join(", ")} (for example WITH or TABLESPACE)`)
  if (b.concurrent && !b.idxname) fail(c, `${where}: CREATE INDEX CONCURRENTLY must name its index (a failed build leaves an invalid index to drop by name)`)
  if (!INDEX_METHODS.has(b.accessMethod ?? "btree")) fail(c, `${where}: USING ${b.accessMethod} (only btree, gin, gist, hash)`)
  for (const p of [...(b.indexParams ?? []), ...(b.indexIncludingParams ?? [])]) {
    const el = p.IndexElem ?? {}
    if (el.opclass?.length || el.opclassopts?.length) fail(c, `${where}: an operator class (default opclasses only)`)
    if (el.collation?.length) fail(c, `${where}: COLLATE`)
    if (el.expr && !exprOk(c, el.expr)) fail(c, `${where}: index expression outside the allowlist`)
  }
  if (b.whereClause && !exprOk(c, b.whereClause)) fail(c, `${where}: partial-index WHERE outside the allowlist`)
  const existing = !c.created.has(relKey(b.relation))
  if (existing && !b.concurrent) fail(c, `${where}: on an existing table without CONCURRENTLY (locks writes)`)
}

const alterTable = (c: Ctx, b: Node) => {
  const where = `ALTER TABLE ${relName(b.relation)}`
  if (b.objtype && b.objtype !== "OBJECT_TABLE") return fail(c, `ALTER ${String(b.objtype).replace("OBJECT_", "")}`)
  if (!inSchema(c, b.relation)) return fail(c, `${where}: outside ${c.schema}`)
  const existing = !c.created.has(relKey(b.relation))
  for (const cmd0 of b.cmds ?? []) {
    const cmd = cmd0.AlterTableCmd ?? {}
    if (cmd.behavior === "DROP_CASCADE") {
      fail(c, `${where}: CASCADE`)
      continue
    }
    switch (cmd.subtype) {
      case "AT_AddColumn":
        columnOk(c, cmd.def?.ColumnDef ?? {}, `${where} ADD COLUMN`, existing)
        break
      case "AT_AddConstraint": {
        const con = cmd.def?.Constraint ?? {}
        if (!constraintOk(c, con, `${where} ADD CONSTRAINT ${con.conname ?? ""}`)) break
        const notValid = con.skip_validation === true && (con.contype === "CONSTR_CHECK" || con.contype === "CONSTR_FOREIGN")
        if (existing && !notValid) {
          if (con.contype === "CONSTR_CHECK") c.liftable.push(`ADD CONSTRAINT ${con.conname ?? "(unnamed)"} validated on an existing table (use CHECK ... NOT VALID)`)
          else fail(c, `${where} ADD CONSTRAINT ${con.conname ?? ""}: ${String(con.contype).replace("CONSTR_", "")} on an existing table`)
        }
        break
      }
      case "AT_ValidateConstraint":
        break
      case "AT_DropConstraint":
        c.liftable.push(`DROP CONSTRAINT ${cmd.name}`)
        break
      case "AT_DropColumn":
        c.liftable.push(`DROP COLUMN ${cmd.name}`)
        break
      case "AT_SetNotNull":
        c.liftable.push(`ALTER COLUMN ${cmd.name} SET NOT NULL`)
        break
      case "AT_AlterColumnType": {
        const col = cmd.def?.ColumnDef ?? {}
        if (!typeOk(c, col.typeName) || (col.raw_default && !exprOk(c, col.raw_default)) || col.collClause) fail(c, `${where} ALTER COLUMN ${cmd.name} TYPE: only a built-in type (no COLLATE, USING within the allowlist)`)
        else c.liftable.push(`ALTER COLUMN ${cmd.name} TYPE (a type change can narrow)`)
        break
      }
      default:
        fail(c, `${where}: ${String(cmd.subtype).replace("AT_", "")}`)
    }
  }
}

const grantOk = (c: Ctx, b: Node) => {
  if (!b.is_grant) return fail(c, "REVOKE (operators revoke with pscale, not migrations)")
  if (b.grant_option) fail(c, "GRANT ... WITH GRANT OPTION")
  if (b.targtype !== "ACL_TARGET_OBJECT") fail(c, "GRANT ON ALL ... IN SCHEMA")
  for (const g of b.grantees ?? []) {
    const spec = g.RoleSpec
    if (spec?.roletype !== "ROLESPEC_CSTRING") fail(c, `GRANT TO ${spec?.roletype === "ROLESPEC_PUBLIC" ? "PUBLIC" : spec?.roletype}`)
    else if (!c.contract.grantees.includes(spec.rolename)) fail(c, `GRANT TO ${spec.rolename}: not a grantee in role-contract.json`)
  }
  const privileges: Array<string> | undefined = b.privileges?.map((p: Node) => String(p.AccessPriv?.priv_name ?? "").toUpperCase())
  if (!privileges) fail(c, "GRANT ALL")
  if (b.objtype === "OBJECT_TABLE") {
    for (const p of privileges ?? []) if (!c.contract.tablePrivileges.includes(p)) fail(c, `GRANT ${p} on a table: not in role-contract.json`)
    for (const o of b.objects ?? []) if (!o.RangeVar?.schemaname || !c.contract.schemas.includes(o.RangeVar.schemaname)) fail(c, `GRANT on ${o.RangeVar ? relName(o.RangeVar) : "?"}: name a schema of role-contract.json`)
  } else if (b.objtype === "OBJECT_SCHEMA") {
    for (const p of privileges ?? []) if (!c.contract.schemaPrivileges.includes(p)) fail(c, `GRANT ${p} on a schema: not in role-contract.json`)
    for (const o of b.objects ?? []) if (!c.contract.schemas.includes(o.String?.sval)) fail(c, `GRANT on schema ${o.String?.sval}: not in role-contract.json`)
  } else fail(c, `GRANT on ${String(b.objtype).replace("OBJECT_", "")}`)
}

const qualifiedIn = (c: Ctx, parts: Array<string>) => (c.tree === "cmux-vm" ? parts.length === 2 && parts[0] === c.schema : parts.length === 1 || parts[0] === c.schema)

const EXTENSIONS = new Set(["pg_trgm", "btree_gin"])

/** Every problem of one file: `never` refuses always; `liftable` refuses unless a contract header names a reason. */
export const statementProblems = (stmts: ReadonlyArray<ParsedStatement>, tree: string, schema: string, contract: TreeRoleContract): { never: Array<string>; liftable: Array<string> } => {
  const c: Ctx = { tree, schema, contract, never: [], liftable: [], created: new Set() }
  // The runner owns the tracking table: no migration may name it (P3-4).
  const touchesTracking = (node: unknown): boolean =>
    Array.isArray(node) ? node.some(touchesTracking) : !!node && typeof node === "object" && ((node as Node).relname === "schema_migrations" || Object.values(node as Node).some(touchesTracking))
  if (stmts.some((s) => touchesTracking(s.node) || JSON.stringify(s.node).includes('"sval":"schema_migrations"'))) c.never.push("names the tracking table schema_migrations (the runner owns it)")
  for (const { kind, node: b } of stmts) {
    switch (kind) {
      case "CreateStmt":
        createTable(c, b)
        break
      case "IndexStmt":
        createIndex(c, b)
        break
      case "AlterTableStmt":
        alterTable(c, b)
        break
      case "CreateSeqStmt":
        if (keysOnly(b, ["sequence", "options", "if_not_exists", "for_identity"]).length || b.for_identity) fail(c, `CREATE SEQUENCE ${relName(b.sequence)}: ${keysOnly(b, ["sequence", "options", "if_not_exists"]).join(", ")}`)
        else if (b.sequence?.relpersistence && b.sequence.relpersistence !== "p") fail(c, `CREATE SEQUENCE ${relName(b.sequence)}: only permanent sequences`)
        else if (!inSchema(c, b.sequence)) fail(c, `CREATE SEQUENCE ${relName(b.sequence)} is outside ${schema}`)
        else if ((b.options ?? []).some((o: Node) => !["start", "increment", "minvalue", "maxvalue", "cache", "cycle", "as"].includes(o.DefElem?.defname))) fail(c, `CREATE SEQUENCE ${relName(b.sequence)}: an option outside START, INCREMENT, MINVALUE, MAXVALUE, CACHE, CYCLE, AS`)
        break
      case "CreateEnumStmt":
        if (!qualifiedIn(c, names(b.typeName))) fail(c, `CREATE TYPE ${names(b.typeName).join(".")} AS ENUM must be ${schema}.<name>`)
        break
      case "AlterEnumStmt":
        if (b.oldVal !== undefined) fail(c, "ALTER TYPE ... RENAME VALUE")
        else if (!qualifiedIn(c, names(b.typeName))) fail(c, `ALTER TYPE ${names(b.typeName).join(".")} is outside ${schema}`)
        break
      case "CreateSchemaStmt":
        if (b.schemaname !== schema || b.schemaElts?.length || b.authrole) fail(c, `CREATE SCHEMA ${b.schemaname}: only ${schema} itself, with nothing inside the statement`)
        break
      case "CommentStmt": {
        const o = b.object
        // COMMENT ON TYPE carries a TypeName; the others a name list or a bare name.
        const parts = ((o?.TypeName?.names ?? o?.List?.items ?? (o?.String ? [o] : [])) as Array<Node>).map((i) => i.String?.sval)
        // Exact name depth per object kind; the first part is the schema (backend: public or unqualified).
        const depth: Record<string, number> = { OBJECT_SCHEMA: 1, OBJECT_TABLE: 2, OBJECT_INDEX: 2, OBJECT_SEQUENCE: 2, OBJECT_TYPE: 2, OBJECT_COLUMN: 3 }
        const want = depth[b.objtype]
        const qualified = tree === "cmux-vm" ? parts.length === want && parts[0] === schema : parts.length === want ? parts[0] === schema : parts.length === (want ?? 0) - 1
        const ok = want !== undefined && (b.objtype === "OBJECT_SCHEMA" ? parts.length === 1 && parts[0] === schema : qualified) && parts.every((p) => typeof p === "string")
        if (!ok) fail(c, `COMMENT ON ${String(b.objtype).replace("OBJECT_", "")} ${parts.join(".")} (outside ${schema}, unqualified, or not a table, column, index, sequence, type or the schema)`)
        break
      }
      case "GrantStmt":
        grantOk(c, b)
        break
      case "CreateExtensionStmt":
        if (tree !== "backend" || !(b.if_not_exists && EXTENSIONS.has(b.extname))) fail(c, `CREATE EXTENSION ${b.extname} (backend only: IF NOT EXISTS ${[...EXTENSIONS].join(", ")})`)
        break
      case "DropStmt": {
        const what = String(b.removeType).replace("OBJECT_", "")
        const objs = (b.objects ?? []).map((o: Node) => names(o.List?.items ?? []))
        if (b.behavior === "DROP_CASCADE") fail(c, `DROP ${what} ... CASCADE`)
        else if (!["OBJECT_TABLE", "OBJECT_INDEX"].includes(b.removeType)) fail(c, `DROP ${what}`)
        else if (!objs.every((p: Array<string>) => qualifiedIn(c, p))) fail(c, `DROP ${what} outside ${schema}`)
        else c.liftable.push(`DROP ${what} ${objs.map((p: Array<string>) => p.join(".")).join(", ")}`)
        break
      }
      case "RenameStmt":
        if (!["OBJECT_TABLE", "OBJECT_COLUMN", "OBJECT_INDEX", "OBJECT_TABCONSTRAINT", "OBJECT_SEQUENCE"].includes(b.renameType)) fail(c, `RENAME of ${String(b.renameType).replace("OBJECT_", "")}`)
        else if (!inSchema(c, b.relation)) fail(c, `RENAME of ${relName(b.relation)}: outside ${schema}`)
        else c.liftable.push(`RENAME (${String(b.renameType).replace("OBJECT_", "")}) ${relName(b.relation)}`)
        break
      case "InsertStmt":
      case "UpdateStmt":
      case "DeleteStmt":
      case "SelectStmt":
      case "MergeStmt":
        fail(c, `${kind.replace("Stmt", "").toUpperCase()}: data statements do not belong in a schema migration (a reviewed data file type is not supported yet)`)
        break
      default:
        fail(c, `${kind.replace(/Stmt$/, "")} is not an allowed migration statement`)
    }
  }
  return { never: c.never, liftable: c.liftable }
}

/**
 * cmux-vm only, a second, independent pass: every relation-like name in the whole tree is in
 * schema `schema` (any node with a relname), qualified type and function names are in the schema
 * or pg_catalog, and SET is refused.
 */
export const confinementProblems = (stmts: ReadonlyArray<ParsedStatement>, schema: string): Array<string> => {
  const problems = new Set<string>()
  const allowed = new Set([schema, "pg_catalog"])
  const visit = (node: unknown, key: string): void => {
    if (Array.isArray(node)) {
      const parts = node.map((n: Node) => n?.String?.sval)
      if (["names", "funcname", "typeName", "domainname", "defnames", "objname", "opname"].includes(key) && parts.length >= 2 && parts.every((p) => typeof p === "string") && !allowed.has(parts[0]!))
        problems.add(`${parts.join(".")} is in schema ${parts[0]}`)
      for (const item of node) visit(item, "")
      return
    }
    if (!node || typeof node !== "object") return
    const n = node as Node
    if (typeof n.relname === "string" && n.schemaname !== schema) problems.add(`${relName(n)} is ${n.schemaname ? `in schema ${n.schemaname}` : `unqualified (name it ${schema}.${n.relname})`}`)
    for (const [k, v] of Object.entries(n)) {
      const b = v as Node
      if (k === "VariableSetStmt") problems.add(`SET ${b.name ?? ""}`.trim())
      if (k === "CreateSchemaStmt" && b.schemaname !== schema) problems.add(`CREATE SCHEMA ${b.schemaname}`)
      if (k === "RenameStmt" && b.renameType === "OBJECT_SCHEMA") problems.add(`ALTER SCHEMA ${b.subname} RENAME`)
      if (k === "GrantStmt" && b.objtype === "OBJECT_SCHEMA") for (const o of (b.objects ?? []) as Array<Node>) if (o.String?.sval !== schema) problems.add(`GRANT on schema ${o.String?.sval}`)
      if (k === "DropStmt")
        for (const o of (b.objects ?? []) as Array<Node>) {
          const parts = names(o.List?.items ?? (o.String ? [o] : []))
          if (b.removeType === "OBJECT_SCHEMA" ? parts[0] !== schema : parts.length < 2 || !allowed.has(parts[0]!)) problems.add(`DROP of ${parts.join(".")}`)
        }
      visit(v, k)
    }
  }
  for (const s of stmts) visit({ [s.kind]: s.node }, "")
  return [...problems]
}
