// Adapted from executor (https://github.com/UsefulSoftwareCo/executor), MIT License, Copyright (c) 2026 Rhys Sullivan
// Upstream: packages/plugins/graphql/src/sdk/extract.ts (unwrapTypeName,
// isNonNull, typeRefToJsonSchema, scalarToJsonSchema, buildInputSchema,
// formatTypeRef, extractFields, extract), the introspection types of
// packages/plugins/graphql/src/sdk/introspect.ts, and the `<kind>.<field>` tool
// naming and mutation approval of packages/plugins/graphql/src/sdk/plugin.ts.
// Changes for cmux: plain TypeScript (no Effect `Match`/`Option`); input
// schemas inline enum and input-object definitions under `$defs`; each field
// gets a cmux op class and default action.

import { defaultActionFor, opClassForGraphql } from "./policy.ts"
import { isRecord, type ToolEntry } from "./types.ts"

export interface IntrospectionTypeRef {
  readonly kind: string
  readonly name?: string | null
  readonly ofType?: IntrospectionTypeRef | null
}

export interface IntrospectionInputValue {
  readonly name: string
  readonly description?: string | null
  readonly type: IntrospectionTypeRef
}

export interface IntrospectionField {
  readonly name: string
  readonly description?: string | null
  readonly args: readonly IntrospectionInputValue[]
  readonly type: IntrospectionTypeRef
  readonly isDeprecated?: boolean
}

export interface IntrospectionType {
  readonly kind: string
  readonly name: string
  readonly description?: string | null
  readonly fields?: readonly IntrospectionField[] | null
  readonly inputFields?: readonly IntrospectionInputValue[] | null
  readonly enumValues?: ReadonlyArray<{ readonly name: string }> | null
}

export interface IntrospectionSchema {
  readonly queryType?: { readonly name: string } | null
  readonly mutationType?: { readonly name: string } | null
  readonly types: readonly IntrospectionType[]
}

export interface ExtractedField {
  readonly fieldName: string
  readonly kind: "query" | "mutation"
  readonly description?: string
  readonly arguments: ReadonlyArray<{ name: string; typeName: string; required: boolean }>
  readonly inputSchema?: Record<string, unknown>
  readonly returnTypeName: string
  readonly deprecated: boolean
}

const unwrapTypeName = (ref: IntrospectionTypeRef): string => (ref.name ? ref.name : ref.ofType ? unwrapTypeName(ref.ofType) : "Unknown")

const isNonNull = (ref: IntrospectionTypeRef): boolean => ref.kind === "NON_NULL"

const scalarToJsonSchema = (name: string): Record<string, unknown> => {
  switch (name) {
    case "String":
    case "ID":
      return { type: "string" }
    case "Int":
      return { type: "integer" }
    case "Float":
      return { type: "number" }
    case "Boolean":
      return { type: "boolean" }
    default:
      return { type: "string", description: `Custom scalar: ${name}` }
  }
}

const typeRefToJsonSchema = (ref: IntrospectionTypeRef): Record<string, unknown> => {
  switch (ref.kind) {
    case "NON_NULL":
      return ref.ofType ? typeRefToJsonSchema(ref.ofType) : {}
    case "LIST":
      return { type: "array", items: ref.ofType ? typeRefToJsonSchema(ref.ofType) : {} }
    case "SCALAR":
      return scalarToJsonSchema(ref.name ?? "String")
    case "ENUM":
      return ref.name ? { $ref: `#/$defs/${ref.name}` } : { type: "string" }
    case "INPUT_OBJECT":
      return ref.name ? { $ref: `#/$defs/${ref.name}` } : { type: "object" }
    case "OBJECT":
    case "INTERFACE":
    case "UNION":
      return { type: "object" }
    default:
      return {}
  }
}

/** Shared `$defs` for every INPUT_OBJECT and ENUM type; tool input schemas point into them. */
export const buildDefinitions = (types: ReadonlyMap<string, IntrospectionType>): Record<string, unknown> => {
  const defs: Record<string, unknown> = {}
  for (const [name, type] of types) {
    if (name.startsWith("__")) continue
    if (type.kind === "INPUT_OBJECT" && type.inputFields) {
      const properties: Record<string, unknown> = {}
      const required: string[] = []
      for (const field of type.inputFields) {
        properties[field.name] = { ...typeRefToJsonSchema(field.type), ...(field.description ? { description: field.description } : {}) }
        if (isNonNull(field.type)) required.push(field.name)
      }
      defs[name] = { type: "object", properties, ...(required.length ? { required } : {}), ...(type.description ? { description: type.description } : {}) }
    }
    if (type.kind === "ENUM" && type.enumValues) {
      defs[name] = { type: "string", enum: type.enumValues.map((v) => v.name), ...(type.description ? { description: type.description } : {}) }
    }
  }
  return defs
}

const buildInputSchema = (args: readonly IntrospectionInputValue[]): Record<string, unknown> | undefined => {
  if (args.length === 0) return undefined
  const properties: Record<string, unknown> = {}
  const required: string[] = []
  for (const arg of args) {
    properties[arg.name] = { ...typeRefToJsonSchema(arg.type), ...(arg.description ? { description: arg.description } : {}) }
    if (isNonNull(arg.type)) required.push(arg.name)
  }
  return { type: "object", properties, ...(required.length ? { required } : {}) }
}

/** GraphQL type notation of a ref, for example `[String!]!`. */
export const formatTypeRef = (ref: IntrospectionTypeRef): string => {
  if (ref.kind === "NON_NULL") return ref.ofType ? `${formatTypeRef(ref.ofType)}!` : "Unknown!"
  if (ref.kind === "LIST") return ref.ofType ? `[${formatTypeRef(ref.ofType)}]` : "[Unknown]"
  return ref.name ?? "Unknown"
}

const extractFields = (kind: "query" | "mutation", typeName: string | undefined, types: ReadonlyMap<string, IntrospectionType>): ExtractedField[] => {
  const type = typeName ? types.get(typeName) : undefined
  if (!type?.fields) return []
  return type.fields
    .filter((f) => !f.name.startsWith("__"))
    .map((field) => {
      const inputSchema = buildInputSchema(field.args)
      return {
        fieldName: field.name,
        kind,
        ...(field.description ? { description: field.description } : {}),
        arguments: field.args.map((a) => ({ name: a.name, typeName: formatTypeRef(a.type), required: isNonNull(a.type) })),
        ...(inputSchema ? { inputSchema } : {}),
        returnTypeName: unwrapTypeName(field.type),
        deprecated: field.isDeprecated === true
      }
    })
}

export class GraphqlExtractionError extends Error {}

/** Accepts `{__schema}` or the full response `{data: {__schema}}` of an introspection query. */
export const introspectionSchemaOf = (value: unknown): IntrospectionSchema | null => {
  const root = isRecord(value) && isRecord(value.data) ? value.data : value
  const schema = isRecord(root) ? root.__schema : undefined
  return isRecord(schema) && Array.isArray(schema.types) ? (schema as unknown as IntrospectionSchema) : null
}

export const extract = (introspection: unknown): { fields: ExtractedField[]; definitions: Record<string, unknown> } => {
  const schema = introspectionSchemaOf(introspection)
  if (!schema) throw new GraphqlExtractionError("Not a GraphQL introspection result")
  const typeMap = new Map<string, IntrospectionType>()
  for (const t of schema.types) if (isRecord(t) && typeof t.name === "string") typeMap.set(t.name, t)
  return {
    fields: [...extractFields("query", schema.queryType?.name, typeMap), ...extractFields("mutation", schema.mutationType?.name, typeMap)],
    definitions: buildDefinitions(typeMap)
  }
}

/** Catalog tools: `query.<field>` and `mutation.<field>`, queries read, mutations ask, destructive-named mutations block. */
export const toolsFromGraphql = (fields: readonly ExtractedField[]): ToolEntry[] =>
  fields.map((f) => {
    const opClass = opClassForGraphql(f.kind, f.fieldName)
    return {
      path: `${f.kind}.${f.fieldName}`,
      title: f.fieldName,
      description: f.description ?? `GraphQL ${f.kind}: ${f.fieldName} -> ${f.returnTypeName}`,
      kind: "graphql" as const,
      method: f.kind,
      target: f.fieldName,
      op_class: opClass,
      default_action: defaultActionFor(opClass),
      ...(f.inputSchema ? { input_schema: f.inputSchema } : {}),
      ...(f.deprecated ? { deprecated: true } : {})
    }
  })
