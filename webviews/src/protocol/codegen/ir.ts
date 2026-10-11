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
  /** Top-level params that name filesystem paths; providers confine them to the token's roots (decision 22). */
  paths: string[];
  /** MCP exposure (decision 21). An op without `mcp` in the IR is `{expose: "never"}`. */
  mcp: IrMcp;
  /** CLI verb, when the op has one (decision 21). */
  cli?: IrCli;
  /** True when the result can carry an `x-cmux-secret` value; never offered to agents (decision 21). */
  secret_output: boolean;
}

export type McpExpose = "default" | "opt_in" | "never";

export interface IrMcp {
  expose: McpExpose;
  group?: string;
}

export interface IrCli {
  /** Verb path relative to the app, e.g. "git status". */
  path: string;
  visible: boolean;
  /** Top-level params taken positionally, in order. */
  positional?: string[];
}

/** MCP tool name of an op: the op name with `.` and `-` as `_` (decision 21). At most 48 characters. */
export function mcpToolName(op: string): string {
  return op.replaceAll(/[.-]/g, "_");
}

export const MCP_TOOL_NAME_MAX = 48;
const CLI_PATH = /^[a-z][a-z0-9-]*( [a-z][a-z0-9-]*){0,2}$/;

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
      // emit-ir always writes `paths` and `secret_output`. A missing one means an older or
      // hand-edited IR, so fail instead of guessing (a guessed `false` would leak secrets).
      paths: stringArray(op.paths, `${where}.paths`),
      secret_output: boolean(op.secret_output, `${where}.secret_output`),
      mcp: parseMcp(op.mcp, `${where}.mcp`),
      ...(op.cli === undefined ? {} : { cli: parseCli(op.cli, `${where}.cli`) }),
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
  checkOpRules(ops, types);
  return { version, namespaces, ops, events, interfaces, types };
}

function boolean(value: unknown, where: string): boolean {
  if (typeof value !== "boolean") throw new IrError(`${where} must be a boolean`);
  return value;
}

function onlyKeys(value: Record<string, unknown>, keys: string[], where: string): void {
  for (const key of Object.keys(value)) {
    if (!keys.includes(key)) throw new IrError(`${where} has unknown key ${JSON.stringify(key)}`);
  }
}

function parseMcp(raw: unknown, where: string): IrMcp {
  if (raw === undefined) return { expose: "never" };
  if (!isRecord(raw)) throw new IrError(`${where} must be an object`);
  onlyKeys(raw, ["expose", "group"], where);
  if (raw.expose !== "default" && raw.expose !== "opt_in" && raw.expose !== "never") {
    throw new IrError(`${where}.expose must be "default", "opt_in" or "never"`);
  }
  return raw.group === undefined
    ? { expose: raw.expose }
    : { expose: raw.expose, group: string(raw.group, `${where}.group`) };
}

function parseCli(raw: unknown, where: string): IrCli {
  if (!isRecord(raw)) throw new IrError(`${where} must be an object`);
  onlyKeys(raw, ["path", "visible", "positional"], where);
  const path = string(raw.path, `${where}.path`);
  if (!CLI_PATH.test(path)) throw new IrError(`${where}.path ${JSON.stringify(path)} must match ${CLI_PATH.source}`);
  const cli: IrCli = { path, visible: boolean(raw.visible, `${where}.visible`) };
  if (raw.positional !== undefined) cli.positional = stringArray(raw.positional, `${where}.positional`);
  return cli;
}

/** Top-level properties of an op's params, following one $ref. */
function paramProperties(params: JsonSchema, types: Record<string, JsonSchema>): Record<string, unknown> {
  let schema: unknown = params;
  const ref =
    isRecord(schema) && typeof schema.$ref === "string" ? /^#\/(?:types|\$defs)\/(.+)$/.exec(schema.$ref) : null;
  if (ref) schema = types[ref[1]];
  return isRecord(schema) && isRecord(schema.properties) ? schema.properties : {};
}

function includesString(schema: unknown): boolean {
  if (!isRecord(schema)) return false;
  return schema.type === "string" || (Array.isArray(schema.type) && schema.type.includes("string"));
}

/** The registry rules a generated client relies on (decisions 21-23); the Rust merge enforces the same. */
function checkOpRules(ops: IrOp[], types: Record<string, JsonSchema>): void {
  const toolNames = new Map<string, string>();
  const cliPaths = new Set<string>();
  for (const op of ops) {
    const params = paramProperties(op.params, types);
    for (const name of op.paths) {
      if (!includesString(params[name])) throw new IrError(`${op.name}: paths entry ${name} is not a string param`);
    }
    for (const name of op.cli?.positional ?? []) {
      if (!(name in params)) throw new IrError(`${op.name}: cli.positional ${name} is not a top-level param`);
    }
    if (op.cli) {
      const key = `${op.owner}\u0000${op.cli.path}`;
      if (cliPaths.has(key))
        throw new IrError(`${op.name}: cli.path ${JSON.stringify(op.cli.path)} is taken in ${op.owner}`);
      cliPaths.add(key);
    }
    // Decision 23: checked for every op, exposed or not, so changing `expose` later cannot collide.
    const tool = mcpToolName(op.name);
    if (tool.length > MCP_TOOL_NAME_MAX) throw new IrError(`${op.name}: MCP tool name ${tool} exceeds 48 characters`);
    const other = toolNames.get(tool);
    if (other) throw new IrError(`${op.name} and ${other} share the MCP tool name ${tool}`);
    toolNames.set(tool, op.name);
  }
}
