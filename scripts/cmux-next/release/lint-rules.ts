/**
 * Statement rules of the migration linter (lint.ts). Three layers:
 *   alwaysProblems       refused even with a contract header (DO, functions, TRUNCATE,
 *                        roles, ownership, schema moves, RLS, triggers, rules, policies,
 *                        session or database settings, COPY, top-level SELECT, grants
 *                        beyond role-contract.json, REVOKE);
 *   expandProblems       an ALLOWLIST of expand statements and ALTER TABLE subcommands;
 *                        anything else needs `-- contract: <reason>`;
 *   confinementProblems  cmux-vm: every name in schema cmux_vm (cmux-old shares the database).
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

export const grantProblems = (b: Node, contract: TreeRoleContract): Array<string> => {
  const problems: Array<string> = []
  if (!b.is_grant) return ["REVOKE narrows what deployed code may do (operators revoke with pscale, not migrations)"]
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

/** Statements no migration may contain, with or without a contract header. */
const ALWAYS: Readonly<Record<string, string>> = {
  DoStmt: "DO block (its statements are not checked)",
  CreateFunctionStmt: "CREATE FUNCTION/PROCEDURE (its body is not checked)",
  TruncateStmt: "TRUNCATE",
  GrantRoleStmt: "GRANT/REVOKE of role membership",
  AlterDefaultPrivilegesStmt: "ALTER DEFAULT PRIVILEGES",
  CreateRoleStmt: "CREATE ROLE (roles are managed with pscale)",
  AlterRoleStmt: "ALTER ROLE",
  AlterRoleSetStmt: "ALTER ROLE ... SET",
  DropRoleStmt: "DROP ROLE",
  ReassignOwnedStmt: "REASSIGN OWNED",
  DropOwnedStmt: "DROP OWNED",
  AlterOwnerStmt: "OWNER TO",
  AlterObjectSchemaStmt: "SET SCHEMA",
  SelectStmt: "a top-level SELECT (it can call any function: setval, set_config, pg_terminate_backend)",
  VariableSetStmt: "SET (session settings belong to the runner)",
  AlterDatabaseStmt: "ALTER DATABASE",
  AlterDatabaseSetStmt: "ALTER DATABASE ... SET",
  AlterSystemStmt: "ALTER SYSTEM",
  CopyStmt: "COPY",
  CreateTrigStmt: "CREATE TRIGGER",
  RuleStmt: "CREATE RULE",
  CreatePolicyStmt: "CREATE POLICY",
  AlterPolicyStmt: "ALTER POLICY",
  CreateEventTrigStmt: "CREATE EVENT TRIGGER",
  AlterEventTrigStmt: "ALTER EVENT TRIGGER",
  LoadStmt: "LOAD",
  CallStmt: "CALL",
  ExecuteStmt: "EXECUTE",
  PrepareStmt: "PREPARE",
  CreatedbStmt: "CREATE DATABASE",
  DropdbStmt: "DROP DATABASE",
  AlterExtensionStmt: "ALTER EXTENSION",
  CreateFdwStmt: "a foreign data wrapper",
  CreateForeignServerStmt: "a foreign server",
  CreateForeignTableStmt: "a foreign table",
  CreateUserMappingStmt: "a user mapping",
  ImportForeignSchemaStmt: "IMPORT FOREIGN SCHEMA",
  CreatePublicationStmt: "a publication",
  AlterPublicationStmt: "a publication",
  CreateSubscriptionStmt: "a subscription",
  AlterSubscriptionStmt: "a subscription",
  SecLabelStmt: "SECURITY LABEL",
  LockStmt: "LOCK",
  ClusterStmt: "CLUSTER",
  ReindexStmt: "REINDEX",
  VacuumStmt: "VACUUM/ANALYZE",
  RefreshMatViewStmt: "REFRESH MATERIALIZED VIEW",
  ListenStmt: "LISTEN",
  NotifyStmt: "NOTIFY",
}

/** ALTER TABLE subcommands no migration may contain. */
const ALWAYS_SUBTYPES: ReadonlyArray<string> = [
  "AT_ChangeOwner",
  "AT_EnableRowSecurity",
  "AT_DisableRowSecurity",
  "AT_ForceRowSecurity",
  "AT_NoForceRowSecurity",
  "AT_EnableTrig",
  "AT_EnableAlwaysTrig",
  "AT_EnableReplicaTrig",
  "AT_DisableTrig",
  "AT_EnableTrigAll",
  "AT_DisableTrigAll",
  "AT_EnableTrigUser",
  "AT_DisableTrigUser",
  "AT_EnableRule",
  "AT_EnableAlwaysRule",
  "AT_EnableReplicaRule",
  "AT_DisableRule",
  "AT_ReplicaIdentity",
  "AT_SetTableSpace",
  "AT_GenericOptions",
]

/** Problems no contract header lifts. */
export const alwaysProblems = (stmts: ReadonlyArray<ParsedStatement>, contract: TreeRoleContract, tree: string): Array<string> => {
  const problems: Array<string> = []
  for (const { kind, node: b } of stmts) {
    if (ALWAYS[kind]) problems.push(ALWAYS[kind]!)
    if (kind === "GrantStmt") problems.push(...grantProblems(b, contract))
    if (kind === "CreateExtensionStmt" && tree === "cmux-vm") problems.push("CREATE EXTENSION (extensions are database-wide; cmux-old shares this database)")
    if (kind === "RenameStmt" && b.renameType === "OBJECT_SCHEMA") problems.push("ALTER SCHEMA ... RENAME")
    if (kind === "AlterTableStmt") for (const c of b.cmds ?? []) if (ALWAYS_SUBTYPES.includes(c.AlterTableCmd?.subtype)) problems.push(`ALTER TABLE ... ${String(c.AlterTableCmd.subtype).replace("AT_", "")}`)
  }
  problems.push(...functionProblems(stmts))
  return problems
}

/**
 * Functions a migration may call anywhere (defaults, checks, backfills): pure or stable built-ins.
 * Anything else (setval, nextval, set_config, query_to_xml, pg_terminate_backend, pg_sleep, dblink,
 * lo_*, ...) can act outside the schema or the transaction, so it is refused even with a header.
 */
export const ALLOWED_FUNCTIONS: ReadonlySet<string> = new Set([
  "now", "gen_random_uuid", "lower", "upper", "length", "char_length", "octet_length", "btrim", "ltrim", "rtrim", "trim",
  "substr", "substring", "left", "right", "lpad", "rpad", "replace", "position", "strpos", "split_part", "concat", "concat_ws",
  "abs", "round", "floor", "ceil", "ceiling", "greatest", "least", "date_trunc", "date_part", "extract", "to_timestamp",
  "jsonb_build_object", "jsonb_build_array", "to_jsonb", "jsonb_typeof", "jsonb_array_length", "jsonb_strip_nulls",
  "array_length", "cardinality", "array_to_string", "string_to_array", "count", "max", "min", "sum", "bool_or", "bool_and",
  "md5", "encode", "decode", "inet", "family", "host", "masklen",
])
const REG_TYPES = new Set(["regclass", "regproc", "regprocedure", "regoper", "regoperator", "regtype", "regrole", "regnamespace", "regconfig", "regdictionary", "regcollation"])

/** Every function call and reg* cast in the whole tree of the statements (any depth). */
export const functionProblems = (stmts: ReadonlyArray<ParsedStatement>): Array<string> => {
  const problems = new Set<string>()
  const visit = (node: unknown): void => {
    if (Array.isArray(node)) return node.forEach(visit)
    if (!node || typeof node !== "object") return
    const n = node as Node
    if (n.FuncCall) {
      const parts: Array<string> = (n.FuncCall.funcname ?? []).map((x: Node) => x.String?.sval)
      const name = parts.at(-1) ?? ""
      if ((parts.length > 1 && parts[0] !== "pg_catalog") || !ALLOWED_FUNCTIONS.has(name)) problems.add(`calls ${parts.join(".")}() (not in the function allowlist)`)
    }
    if (n.TypeCast) {
      const type: Array<string> = (n.TypeCast.typeName?.names ?? []).map((x: Node) => x.String?.sval)
      if (REG_TYPES.has(type.at(-1) ?? "")) problems.add(`casts to ${type.at(-1)} (a name resolved at run time)`)
    }
    for (const v of Object.values(n)) visit(v)
  }
  stmts.forEach((s) => visit(s.node))
  return [...problems]
}

/** A DEFAULT that needs no table rewrite: constants, casts of constants, CURRENT_* and now(). */
const stableDefault = (e: Node | undefined): boolean => {
  if (!e) return true
  if (e.A_Const || e.SQLValueFunction) return true
  if (e.TypeCast) return stableDefault(e.TypeCast.arg)
  if (e.A_ArrayExpr) return (e.A_ArrayExpr.elements ?? []).every(stableDefault)
  if (e.FuncCall) return (e.FuncCall.funcname ?? []).map((n: Node) => n.String?.sval).join(".").replace(/^pg_catalog\./, "") === "now" && !(e.FuncCall.args ?? []).length
  return false
}

const hasColumnRef = (node: unknown): boolean =>
  Array.isArray(node) ? node.some(hasColumnRef) : !!node && typeof node === "object" && ("ColumnRef" in (node as Node) || Object.values(node as Node).some(hasColumnRef))
/** No WHERE, or one that reads no column (`true`, `1 = 1`), touches every row. */
const everyRow = (where: Node | undefined) => !where || !hasColumnRef(where)

const EXTENSIONS = new Set(["pg_trgm", "btree_gin"])

/** Expand allowlist: problems a contract header lifts (empty: an expand file). */
export const expandProblems = (stmts: ReadonlyArray<ParsedStatement>, tree: string): Array<string> => {
  const problems: Array<string> = []
  const created = new Set<string>()
  for (const { kind, node: b } of stmts) {
    if (ALWAYS[kind] || kind === "GrantStmt") continue // alwaysProblems reports these
    switch (kind) {
      case "CreateStmt":
        created.add(relKey(b.relation))
        break
      case "CreateSchemaStmt":
      case "CommentStmt":
      case "InsertStmt":
      case "CreateEnumStmt":
      case "CreateSeqStmt":
      case "CompositeTypeStmt":
      case "CreateDomainStmt":
        break
      case "CreateExtensionStmt":
        if (tree === "backend" && !(b.if_not_exists && EXTENSIONS.has(b.extname))) problems.push(`CREATE EXTENSION must be IF NOT EXISTS and one of ${[...EXTENSIONS].join(", ")}`)
        break
      case "AlterEnumStmt":
        if (b.oldVal !== undefined) problems.push("ALTER TYPE ... RENAME VALUE")
        break
      case "UpdateStmt":
        if (everyRow(b.whereClause)) problems.push(`UPDATE ${relName(b.relation)} without a WHERE that limits rows`)
        break
      case "DeleteStmt":
        if (everyRow(b.whereClause)) problems.push(`DELETE FROM ${relName(b.relation)} without a WHERE that limits rows`)
        break
      case "IndexStmt": {
        const existing = !created.has(relKey(b.relation))
        if (existing && b.unique) problems.push(`CREATE UNIQUE INDEX on existing table ${relName(b.relation)} can reject writes from deployed code`)
        else if (existing && !b.concurrent) problems.push(`CREATE INDEX on existing table ${relName(b.relation)} without CONCURRENTLY locks writes`)
        break
      }
      case "AlterTableStmt": {
        if (b.objtype && b.objtype !== "OBJECT_TABLE") {
          problems.push(`ALTER ${String(b.objtype).replace("OBJECT_", "")}`)
          break
        }
        const existing = !created.has(relKey(b.relation))
        for (const c of b.cmds ?? []) {
          const cmd = c.AlterTableCmd ?? {}
          if (ALWAYS_SUBTYPES.includes(cmd.subtype)) continue
          if (!existing) continue // a table created in this file may be shaped freely
          switch (cmd.subtype) {
            case "AT_AddColumn": {
              const col = cmd.def?.ColumnDef ?? {}
              const cons: Array<Node> = (col.constraints ?? []).map((x: Node) => x.Constraint ?? {})
              const types = new Set(cons.map((x) => x.contype))
              if ((types.has("CONSTR_NOTNULL") || types.has("CONSTR_PRIMARY")) && !types.has("CONSTR_DEFAULT")) problems.push(`ADD COLUMN ${col.colname} NOT NULL without DEFAULT`)
              if (types.has("CONSTR_UNIQUE") || types.has("CONSTR_PRIMARY")) problems.push(`ADD COLUMN ${col.colname} UNIQUE/PRIMARY KEY on an existing table`)
              if (types.has("CONSTR_IDENTITY") || types.has("CONSTR_GENERATED")) problems.push(`ADD COLUMN ${col.colname} IDENTITY/GENERATED rewrites the table`)
              for (const d of cons.filter((x) => x.contype === "CONSTR_DEFAULT")) if (!stableDefault(d.raw_expr)) problems.push(`ADD COLUMN ${col.colname} with a DEFAULT that may be volatile rewrites the table`)
              break
            }
            case "AT_ColumnDefault":
              if (cmd.def === undefined) problems.push(`ALTER COLUMN ${cmd.name} DROP DEFAULT`)
              break
            case "AT_DropNotNull":
            case "AT_ValidateConstraint":
              break
            case "AT_AddConstraint": {
              const con = cmd.def?.Constraint ?? {}
              const notValid = con.skip_validation === true && (con.contype === "CONSTR_CHECK" || con.contype === "CONSTR_FOREIGN")
              if (!notValid) problems.push(`ADD CONSTRAINT ${con.conname ?? "(unnamed)"} validated on an existing table (use CHECK or FOREIGN KEY ... NOT VALID)`)
              break
            }
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
            default:
              problems.push(`ALTER TABLE ... ${String(cmd.subtype).replace("AT_", "")} is not in the expand allowlist`)
          }
        }
        break
      }
      case "DropStmt":
        problems.push(`DROP ${String(b.removeType).replace("OBJECT_", "")}`)
        break
      case "RenameStmt":
        problems.push(`RENAME (${String(b.renameType).replace("OBJECT_", "")})`)
        break
      default:
        problems.push(`${kind.replace(/Stmt$/, "")} is not in the expand allowlist`)
    }
  }
  return problems
}

/** Keys whose value is a name list that CREATES an object (it must be <schema>.<name>). */
const CREATING_NAME = new Set(["CreateEnumStmt.typeName", "CreateDomainStmt.domainname", "DefineStmt.defnames", "CreateConversionStmt.conversion_name", "CreateStatsStmt.defnames"])
/** Keys whose value is a (possibly qualified) name list of an existing object. */
const NAME_LISTS = new Set(["names", "funcname", "typeName", "domainname", "defnames", "objname", "opname"])

/**
 * cmux-vm only: every object a statement names is in schema `schema`. cmux-old
 * (web/, schema public) shares the cmux-prod database, so this holds even with
 * a contract header. Any node with a relname (table, view, sequence, CTAS
 * target, policy table, composite type) must name the schema; a qualified type
 * or function must be in the schema or pg_catalog; created types and domains
 * must be qualified; another schema's CREATE/DROP/GRANT is refused.
 */
export const confinementProblems = (stmts: ReadonlyArray<ParsedStatement>, schema: string): Array<string> => {
  const problems = new Set<string>()
  const allowed = new Set([schema, "pg_catalog"])
  const visit = (node: unknown, key: string, parentKind: string): void => {
    if (Array.isArray(node)) {
      const parts = node.map((n: Node) => n?.String?.sval)
      if (CREATING_NAME.has(`${parentKind}.${key}`)) {
        if (parts.length !== 2 || parts[0] !== schema) problems.add(`${parts.join(".")} is created outside ${schema} (name it ${schema}.${parts.at(-1)})`)
      } else if (NAME_LISTS.has(key) && parts.length >= 2 && parts.every((p) => typeof p === "string") && !allowed.has(parts[0]!)) {
        problems.add(`${parts.join(".")} is in schema ${parts[0]}`)
      }
      for (const item of node) visit(item, "", parentKind)
      return
    }
    if (!node || typeof node !== "object") return
    const n = node as Node
    if (typeof n.relname === "string" && n.schemaname !== schema) problems.add(`${relName(n)} is ${n.schemaname ? `in schema ${n.schemaname}` : `unqualified (name it ${schema}.${n.relname})`}`)
    for (const [k, v] of Object.entries(n)) {
      const kind = /^[A-Z]/.test(k) ? k : parentKind
      if (k === "CreateSchemaStmt" && (v as Node).schemaname !== schema) problems.add(`CREATE SCHEMA ${(v as Node).schemaname}`)
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
      if (k === "CommentStmt") {
        const o = (v as Node).object
        const parts = ((o?.List?.items ?? (o?.String ? [o] : [])) as Array<Node>).map((i) => i.String?.sval)
        const isSchema = (v as Node).objtype === "OBJECT_SCHEMA"
        if (isSchema ? parts[0] !== schema : parts.length < 2 || parts[0] !== schema) problems.add(`COMMENT ON ${parts.join(".")} (outside ${schema} or unqualified)`)
      }
      if (k === "VariableSetStmt") problems.add(`SET ${(v as Node).name ?? ""}`.trim())
      if (k === "RenameStmt" && (v as Node).renameType === "OBJECT_SCHEMA") problems.add(`ALTER SCHEMA ${(v as Node).subname} RENAME TO ${(v as Node).newname}`)
      visit(v, k, kind)
    }
  }
  for (const s of stmts) visit({ [s.kind]: s.node }, "", s.kind)
  return [...problems]
}
