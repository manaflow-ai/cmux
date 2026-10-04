// Shape of the committed pane protocol IR (`cmux-tui/spec/pane-protocol.json`, spec:
// "Schema source and codegen"). The codegen reads only this.

export type JsonSchema = boolean | { [keyword: string]: unknown };

export interface IrNamespace {
  name: string;
  owner: string;
}

export interface IrOp {
  name: string;
  /** "first-party" or "app:<id>". */
  owner: string;
  /** Older names that still route to this op (receivers validate them with the same schema). */
  aliases: string[];
  /** read | mutation | stream. */
  kind: string;
  scope: string;
  params: JsonSchema;
  result: JsonSchema;
  errors: string[];
}

export interface IrEvent {
  name: string;
  scope: string;
  data: JsonSchema;
}

/**
 * Interfaces use the cmux-app-host shape ({name, version, docs, props, methods, events, status}).
 * The codegen only needs `name`; the rest is carried through as metadata.
 */
export interface IrInterface {
  name: string;
  [key: string]: unknown;
}

export interface Ir {
  version: string;
  namespaces: IrNamespace[];
  ops: IrOp[];
  events: IrEvent[];
  interfaces: IrInterface[];
  types: Record<string, JsonSchema>;
}

export class IrError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "IrError";
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isSchema(value: unknown): value is JsonSchema {
  return typeof value === "boolean" || isRecord(value);
}

function stringArray(value: unknown, where: string): string[] {
  if (!Array.isArray(value) || !value.every((item) => typeof item === "string")) {
    throw new IrError(`${where} must be an array of strings`);
  }
  return value;
}

function string(value: unknown, where: string): string {
  if (typeof value !== "string" || value.length === 0) throw new IrError(`${where} must be a non-empty string`);
  return value;
}

/** Checks the IR's top-level shape and returns it typed. Schema keywords are checked by the compilers. */
export function parseIr(raw: unknown): Ir {
  if (!isRecord(raw)) throw new IrError("IR must be a JSON object");
  const version = string(raw.version, "version");
  if (!Array.isArray(raw.namespaces)) throw new IrError("namespaces must be an array");
  const namespaces = raw.namespaces.map((ns: unknown, index) => {
    if (!isRecord(ns)) throw new IrError(`namespaces[${index}] must be an object`);
    return {
      name: string(ns.name, `namespaces[${index}].name`),
      owner: string(ns.owner, `namespaces[${index}].owner`),
    };
  });
  if (!Array.isArray(raw.ops)) throw new IrError("ops must be an array");
  const ops = raw.ops.map((op: unknown, index) => {
    if (!isRecord(op)) throw new IrError(`ops[${index}] must be an object`);
    const where = `ops[${index}]`;
    if (!isSchema(op.params) || !isSchema(op.result)) throw new IrError(`${where} params and result must be schemas`);
    return {
      name: string(op.name, `${where}.name`),
      kind: string(op.kind, `${where}.kind`),
      scope: string(op.scope, `${where}.scope`),
      params: op.params,
      result: op.result,
      errors: op.errors === undefined ? [] : stringArray(op.errors, `${where}.errors`),
      owner: op.owner === undefined ? "first-party" : string(op.owner, `${where}.owner`),
      aliases: op.aliases === undefined ? [] : stringArray(op.aliases, `${where}.aliases`),
    };
  });
  const events = (Array.isArray(raw.events) ? raw.events : []).map((event: unknown, index) => {
    if (!isRecord(event)) throw new IrError(`events[${index}] must be an object`);
    const where = `events[${index}]`;
    if (!isSchema(event.data)) throw new IrError(`${where}.data must be a schema`);
    return {
      name: string(event.name, `${where}.name`),
      scope: string(event.scope, `${where}.scope`),
      data: event.data,
    };
  });
  const interfaces = (Array.isArray(raw.interfaces) ? raw.interfaces : []).map((iface: unknown, index) => {
    if (!isRecord(iface)) throw new IrError(`interfaces[${index}] must be an object`);
    return { ...iface, name: string(iface.name, `interfaces[${index}].name`) };
  });
  const rawTypes = raw.types ?? {};
  if (!isRecord(rawTypes)) throw new IrError("types must be an object");
  const types: Record<string, JsonSchema> = {};
  for (const [name, schema] of Object.entries(rawTypes)) {
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name))
      throw new IrError(`type name ${JSON.stringify(name)} is not an identifier`);
    if (!isSchema(schema)) throw new IrError(`types.${name} must be a schema`);
    types[name] = schema;
  }
  const seen = new Set<string>();
  for (const name of [...ops.flatMap((op) => [op.name, ...op.aliases]), ...events.map((event) => event.name)]) {
    if (seen.has(name)) throw new IrError(`duplicate op, alias or event name ${name}`);
    seen.add(name);
  }
  return { version, namespaces, ops, events, interfaces, types };
}
