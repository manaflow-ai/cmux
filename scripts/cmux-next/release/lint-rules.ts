/** Statement rules of the migration linter (lint.ts): expand-only, grants, cmux-vm schema confinement. */
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

