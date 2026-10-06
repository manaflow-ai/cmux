// The thread widget contract (schemas/widgets): schema validation, the caps in limits.json that
// JSON Schema cannot express (UTF-8 and compact-JSON byte sizes, the HTML digest), the exact
// dataPatch rules and the render policy. acpmux (Rust) and the Swift host implement the same rules
// and replay the same vectors (schemas/widgets/vectors/*.json).
import bridgeSchema from "../../../../../../schemas/widgets/bridge.schema.json";
import kindsSchema from "../../../../../../schemas/widgets/kinds.schema.json";
import limitsFile from "../../../../../../schemas/widgets/limits.json";
import recordSchema from "../../../../../../schemas/widgets/record.schema.json";
import settingsSchema from "../../../../../../schemas/widgets/settings.schema.json";
import tokensSchema from "../../../../../../schemas/widgets/tokens.schema.json";
import toolsSchema from "../../../../../../schemas/widgets/tools.schema.json";
import { jsonEqual, SchemaSet } from "./jsonSchema";

export const WIDGET_SCHEMA_BASE = "https://cmux.com/schemas/widgets/";
export const widgetLimits = limitsFile;

export const widgetSchemas = new SchemaSet([
  kindsSchema,
  recordSchema,
  toolsSchema,
  bridgeSchema,
  tokensSchema,
  settingsSchema,
]);

/// schema: the value does not match its JSON Schema. too_large: a byte cap in limits.json.
export type ContractError = "schema" | "too_large";
export type ContractIssue = { error: ContractError; path: string; message: string };

const encoder = new TextEncoder();

export const utf8Bytes = (text: string) => encoder.encode(text).length;

/// Compact JSON (no insignificant whitespace), the unit of every JSON byte cap.
export const compactJsonBytes = (value: unknown) => utf8Bytes(JSON.stringify(value) ?? "null");

const isObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const DATA_KINDS = new Set(["cmux.chart", "cmux.table", "cmux.metric", "cmux.diagram", "cmux.tree", "cmux.timeline"]);

function sizeIssues(target: string, value: unknown): ContractIssue[] {
  const issues: ContractIssue[] = [];
  const over = (path: string, message: string) => issues.push({ error: "too_large", path, message });
  const { record, bridge } = widgetLimits;
  const fragment = target.split("#")[1] ?? "";
  if (!isObject(value)) return issues;
  if (
    target.startsWith("record.schema.json") ||
    fragment === "/$defs/widgetShowInput" ||
    fragment === "/$defs/widgetUpdateInput" ||
    fragment === "/$defs/widgetCheckInput"
  ) {
    const spec = value.spec;
    if (
      value.kind === "cmux.html" &&
      isObject(spec) &&
      typeof spec.html === "string" &&
      utf8Bytes(spec.html) > record.codeHtmlMaxBytes
    ) {
      over("/spec/html", `the document is over ${record.codeHtmlMaxBytes} bytes`);
    }
    if (
      (typeof value.kind !== "string" || DATA_KINDS.has(value.kind)) &&
      compactJsonBytes({ spec: value.spec ?? null, data: value.data ?? null }) > record.dataSpecAndDataMaxBytes
    ) {
      over("", `spec and data are over ${record.dataSpecAndDataMaxBytes} bytes`);
    }
    if (value.state !== undefined && compactJsonBytes(value.state) > record.stateMaxBytes)
      over("/state", `state is over ${record.stateMaxBytes} bytes`);
  }
  if (target.startsWith("bridge.schema.json")) {
    if (compactJsonBytes(value) > bridge.messageMaxBytes)
      over("", `the message is over ${bridge.messageMaxBytes} bytes`);
    const params = isObject(value.params) ? value.params : {};
    if (value.method === "cmux/state/set" && compactJsonBytes(params.state) > record.stateMaxBytes)
      over("/params/state", `state is over ${record.stateMaxBytes} bytes`);
    if (
      value.method === "ui/message" &&
      isObject(params.content) &&
      typeof params.content.text === "string" &&
      utf8Bytes(params.content.text) > bridge.agentMessageMaxBytes
    ) {
      over("/params/content/text", `the message is over ${bridge.agentMessageMaxBytes} bytes`);
    }
    if (
      value.method === "cmux/cap/request" &&
      params.cap === "agent.event" &&
      isObject(params.params) &&
      params.params.data !== undefined &&
      compactJsonBytes(params.params.data) > bridge.agentEventMaxBytes
    ) {
      over("/params/params/data", `event data is over ${bridge.agentEventMaxBytes} bytes`);
    }
  }
  return issues;
}

/// Validate `value` against a widget schema. `target` is a schema file name with an optional
/// fragment, for example "record.schema.json" or "tools.schema.json#/$defs/widgetShowInput".
/// Schema issues come first; byte caps are checked only for a value that matches the schema.
export function validateWidgetContract(target: string, value: unknown): ContractIssue[] {
  const schemaIssues = widgetSchemas.validate(new URL(target, WIDGET_SCHEMA_BASE).toString(), value);
  if (schemaIssues.length > 0) {
    return schemaIssues.map((issue) => ({
      error: "schema",
      path: issue.path,
      message: `${issue.keyword}: ${issue.message}`,
    }));
  }
  return sizeIssues(target, value);
}

/// Lowercase hex SHA-256 of the document's UTF-8 bytes (record spec.sha256 for cmux.html).
export async function codeWidgetDigest(html: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(html));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

/// True when a stored cmux.html spec is unchanged since acpmux wrote it. A reader never runs a
/// document whose digest does not match (the widget is quarantined: digest).
export async function codeWidgetDigestMatches(spec: { html: string; sha256: string }): Promise<boolean> {
  return (await codeWidgetDigest(spec.html)) === spec.sha256;
}

export type PatchOperation =
  | { op: "set"; path: string; value: unknown }
  | { op: "append"; path: string; values: unknown[]; keepLast?: number }
  | { op: "remove"; path: string; where?: { field: string; equals: unknown } };

export type PatchFailure =
  | "parent_missing"
  | "not_container"
  | "index_out_of_range"
  | "bad_index"
  | "target_missing"
  | "not_array"
  | "invalid_result"
  | "too_large";

export type PatchResult = { ok: true; data: unknown } | { ok: false; op: number; reason: PatchFailure };

class PatchError extends Error {
  constructor(readonly reason: PatchFailure) {
    super(reason);
  }
}

const tokens = (path: string) =>
  path
    .slice(1)
    .split("/")
    .map((token) => token.replaceAll("~1", "/").replaceAll("~0", "~"));

const ARRAY_INDEX = /^(0|[1-9][0-9]*)$/;

/// An index of an existing item: set never grows an array (append does).
function arrayIndex(token: string, length: number): number {
  if (!ARRAY_INDEX.test(token)) throw new PatchError("bad_index");
  const index = Number(token);
  if (index >= length) throw new PatchError("index_out_of_range");
  return index;
}

function child(container: unknown, token: string, missing: PatchFailure): unknown {
  if (Array.isArray(container)) {
    if (!ARRAY_INDEX.test(token)) throw new PatchError("bad_index");
    const index = Number(token);
    if (index >= container.length) throw new PatchError(missing);
    return container[index];
  }
  if (isObject(container)) {
    if (!Object.prototype.hasOwnProperty.call(container, token)) throw new PatchError(missing);
    return container[token];
  }
  throw new PatchError(missing === "target_missing" ? "target_missing" : "not_container");
}

function resolve(root: unknown, path: string[], missing: PatchFailure): unknown {
  let node = root;
  for (const token of path) node = child(node, token, missing);
  return node;
}

/// Sets an own, enumerable key, also for names such as __proto__ that a plain assignment would
/// treat as the prototype.
function setKey(target: Record<string, unknown>, key: string, value: unknown) {
  Object.defineProperty(target, key, { value, writable: true, enumerable: true, configurable: true });
}

function applyOperation(root: unknown, operation: PatchOperation) {
  const path = tokens(operation.path);
  const last = path[path.length - 1] ?? "";
  switch (operation.op) {
    case "set": {
      const parent = resolve(root, path.slice(0, -1), "parent_missing");
      if (Array.isArray(parent)) parent[arrayIndex(last, parent.length)] = structuredClone(operation.value);
      else if (isObject(parent)) setKey(parent, last, structuredClone(operation.value));
      else throw new PatchError("not_container");
      return;
    }
    case "append": {
      const target = resolve(root, path, "target_missing");
      if (!Array.isArray(target)) throw new PatchError("not_array");
      target.push(...structuredClone(operation.values));
      if (operation.keepLast !== undefined && target.length > operation.keepLast)
        target.splice(0, target.length - operation.keepLast);
      return;
    }
    case "remove": {
      if (operation.where) {
        const target = resolve(root, path, "target_missing");
        if (!Array.isArray(target)) throw new PatchError("not_array");
        const { field, equals } = operation.where;
        const kept = target.filter(
          (item) =>
            !(isObject(item) && Object.prototype.hasOwnProperty.call(item, field) && jsonEqual(item[field], equals)),
        );
        target.splice(0, target.length, ...kept);
        return;
      }
      const parent = resolve(root, path.slice(0, -1), "target_missing");
      if (Array.isArray(parent)) {
        if (!ARRAY_INDEX.test(last)) throw new PatchError("bad_index");
        const index = Number(last);
        if (index >= parent.length) throw new PatchError("target_missing");
        parent.splice(index, 1);
      } else if (isObject(parent)) {
        if (!Object.prototype.hasOwnProperty.call(parent, last)) throw new PatchError("target_missing");
        delete parent[last];
      } else {
        throw new PatchError("target_missing");
      }
      return;
    }
  }
}

/// Apply a dataPatch (record.schema.json#/$defs/dataPatch) to a copy of `data`. All or nothing:
/// on a failure the caller keeps the old data and rev. `dataSchema` (a target for
/// validateWidgetContract, for example "kinds.schema.json#/$defs/rowsData") checks the result.
export function applyDataPatch(data: unknown, patch: readonly PatchOperation[], dataSchema?: string): PatchResult {
  const copy = JSON.parse(JSON.stringify(data)) as unknown;
  for (const [index, operation] of patch.entries()) {
    try {
      applyOperation(copy, operation);
    } catch (error) {
      if (error instanceof PatchError) return { ok: false, op: index, reason: error.reason };
      throw error;
    }
  }
  const lastOp = patch.length - 1;
  if (dataSchema && widgetSchemas.validate(new URL(dataSchema, WIDGET_SCHEMA_BASE).toString(), copy).length > 0) {
    return { ok: false, op: lastOp, reason: "invalid_result" };
  }
  if (compactJsonBytes(copy) > widgetLimits.record.dataSpecAndDataMaxBytes)
    return { ok: false, op: lastOp, reason: "too_large" };
  return { ok: true, data: copy };
}

export type WidgetTier = "builtin" | "data" | "code";
export type PaneOrigin = "local" | "paired" | "cloud" | "web";
export type CodeWidgetsSetting = "on" | "off";

/// The default of agentPane.widgets.code, read from settings.schema.json (its only source).
export const codeWidgetsDefault = settingsSchema.properties["agentPane.widgets.code"].default as CodeWidgetsSetting;

export function widgetTier(kind: string): WidgetTier {
  if (kind === "cmux.html") return "code";
  return DATA_KINDS.has(kind) ? "data" : "builtin";
}

export type WidgetPolicyInput = {
  kind: string;
  /// The resolved agentPane.widgets.code value (codeWidgetsDefault when the user set nothing).
  code: CodeWidgetsSetting;
  pane: PaneOrigin;
  quarantined: boolean;
};

/// native: the pane's own renderer (T0, T1). sandbox: the code widget runs in its sandbox frame.
/// source: the title, Show source and Open as file only. capabilities: whether the widget may
/// request any capability (only a running code widget in the local app pane).
export type WidgetPolicy = { render: "native" | "sandbox" | "source"; capabilities: boolean };

export function widgetPolicy(input: WidgetPolicyInput): WidgetPolicy {
  const tier = widgetTier(input.kind);
  if (tier !== "code") return { render: "native", capabilities: false };
  if (input.code === "off" || input.quarantined) return { render: "source", capabilities: false };
  return { render: "sandbox", capabilities: input.pane === "local" };
}
