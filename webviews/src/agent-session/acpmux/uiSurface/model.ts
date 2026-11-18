// The normalized surface an agent's view becomes (`cmux.ui-surface/1`,
// plans/cmux-next/agent-ui-surfaces-DESIGN.md): Rust (cmux-tui/crates/cmux-ui-surfaces) parses,
// validates, binds and caps A2UI and MCP Apps input and emits only this; the pane draws only this.
// This reader is a second line, not the validator: anything that does not have this shape reads as
// no surface, and a node it does not know (or one missing what it needs) reads as a `fallback` node
// with inert text, so a newer Rust never breaks an older page. Every string is drawn as text.

export const UI_SURFACE_SCHEMA = "cmux.ui-surface/1";

export type UiSurfaceA11y = {
  label?: string;
  description?: string;
  live?: "polite" | "assertive";
  hidden?: boolean;
};

export type UiSurfaceAction = { id: string; name: string; privileged?: boolean };
export type UiSurfaceOption = { value: string; label: string };
export type UiSurfaceFact = { label: string; value: string };

type Base = { id: string; a11y?: UiSurfaceA11y };

export type UiTextNode = Base & { type: "text"; text: string; style: "body" | "heading" | "caption" | "code" };
export type UiStackNode = Base & { type: "stack"; axis: "v" | "h"; children: UiNode[] };
export type UiCardNode = Base & { type: "card"; children: UiNode[] };
export type UiListNode = Base & { type: "list"; children: UiNode[] };
export type UiDividerNode = Base & { type: "divider" };
export type UiIconNode = Base & { type: "icon"; name: string };
export type UiImageNode = Base & { type: "image"; alt: string };
export type UiButtonNode = Base & {
  type: "button";
  label: string;
  action?: UiSurfaceAction;
  variant: "primary" | "secondary" | "danger";
};
export type UiFieldInput = "text" | "checkbox" | "choice" | "slider" | "date";
export type UiFieldValue = string | number | boolean | string[];
export type UiFieldNode = Base & {
  type: "field";
  label: string;
  input: UiFieldInput;
  value?: UiFieldValue;
  options?: UiSurfaceOption[];
  multi?: boolean;
  min?: number;
  max?: number;
  bind?: string;
  /// A text field whose value is hidden as typed (Rust `secure`).
  secure?: boolean;
};
export type UiApprovalNode = Base & {
  type: "approval";
  title: string;
  detail?: string;
  risk: "low" | "medium" | "high";
  facts: UiSurfaceFact[];
  approve?: UiSurfaceAction;
  deny?: UiSurfaceAction;
};
export type UiReviewOption = { id: string; label: string; detail?: string };
export type UiReviewNode = Base & {
  type: "review";
  title: string;
  prompt?: string;
  options: UiReviewOption[];
  multi?: boolean;
  submit?: UiSurfaceAction;
  /// The field values key the review's pick is sent under; the review's own id when absent.
  bind?: string;
  /// The options picked already (Rust `selected`).
  selected?: string[];
};
export type UiTableColumn = { key: string; label: string; align?: "left" | "center" | "right" };
export type UiTableNode = Base & { type: "table"; columns: UiTableColumn[]; rows: string[][]; truncated?: boolean };
export type UiChartPoint = { x: string | number; y: number };
export type UiChartNode = Base & {
  type: "chart";
  kind: "bar" | "line" | "pie";
  series: { name: string; points: UiChartPoint[] }[];
  yLabel?: string;
};
export type UiProgressNode = Base & {
  type: "progress";
  label: string;
  value?: number;
  max?: number;
  state: "running" | "done" | "failed";
};
export type UiFallbackNode = Base & { type: "fallback"; text: string };

export type UiNode =
  | UiTextNode
  | UiStackNode
  | UiCardNode
  | UiListNode
  | UiDividerNode
  | UiIconNode
  | UiImageNode
  | UiButtonNode
  | UiFieldNode
  | UiApprovalNode
  | UiReviewNode
  | UiTableNode
  | UiChartNode
  | UiProgressNode
  | UiFallbackNode;

export type UiSurfaceSource = {
  kind: "a2ui" | "mcp-app";
  server?: string;
  tool?: string;
  resourceUri?: string;
  catalogId?: string;
  /// The server is not one the person connected: the source line says "claimed".
  claimed?: boolean;
};

export type UiSurfaceFrame = { html: string; csp?: string; height?: number };

/// An action waiting for the person's confirmation: Rust's answer to `uiSurfaceAction`.
export type UiSurfacePending = {
  requestId: string;
  actionId: string;
  /// Host-written: what Confirm sends and to whom, in plain words.
  summary: string;
  sends: UiSurfaceFact[];
  target: string;
};

export type UiSurface = {
  schema: typeof UI_SURFACE_SCHEMA;
  surfaceId: string;
  source: UiSurfaceSource;
  status: "streaming" | "ready" | "error";
  error?: string;
  title?: string;
  root?: UiNode;
  frame?: UiSurfaceFrame | null;
  pending?: UiSurfacePending | null;
};

/// The field values a surface holds while the person edits, keyed by each field's `bind`.
export type UiSurfaceValues = Record<string, UiFieldValue>;

// ---------- reading ----------

type Json = Record<string, unknown>;
const isRecord = (value: unknown): value is Json =>
  typeof value === "object" && value !== null && !Array.isArray(value);
const str = (value: unknown): string | undefined => (typeof value === "string" ? value : undefined);
const num = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isFinite(value) ? value : undefined;
const oneOf = <T extends string>(value: unknown, allowed: readonly T[], fallback: T): T =>
  allowed.includes(value as T) ? (value as T) : fallback;
const optionalOneOf = <T extends string>(value: unknown, allowed: readonly T[]): T | undefined =>
  allowed.includes(value as T) ? (value as T) : undefined;

/// Mirrors Rust's caps (DESIGN "Caps"): a page never draws past what Rust would have cut.
export const UI_SURFACE_CAPS = { depth: 32, nodes: 512, tableRows: 200, chartPoints: 1000, string: 4096 } as const;

const capped = (value: string) =>
  value.length > UI_SURFACE_CAPS.string ? value.slice(0, UI_SURFACE_CAPS.string) : value;
const text = (value: unknown): string => capped(str(value) ?? "");

function readA11y(value: unknown): UiSurfaceA11y | undefined {
  if (!isRecord(value)) return undefined;
  const a11y: UiSurfaceA11y = {};
  const label = str(value.label);
  const description = str(value.description);
  const live = optionalOneOf(value.live, ["polite", "assertive"] as const);
  if (label) a11y.label = capped(label);
  if (description) a11y.description = capped(description);
  if (live) a11y.live = live;
  if (value.hidden === true) a11y.hidden = true;
  return Object.keys(a11y).length ? a11y : undefined;
}

function readAction(value: unknown): UiSurfaceAction | undefined {
  if (!isRecord(value)) return undefined;
  const id = str(value.id);
  const name = str(value.name);
  if (!id || !name) return undefined;
  return { id, name: capped(name), ...(value.privileged === true ? { privileged: true } : {}) };
}

function readPairs<K extends string, V extends string>(value: unknown, key: K, val: V): Record<K | V, string>[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((entry) => {
    if (!isRecord(entry)) return [];
    const a = str(entry[key]) ?? (typeof entry[key] === "number" ? String(entry[key]) : undefined);
    const b = str(entry[val]) ?? (typeof entry[val] === "number" ? String(entry[val]) : undefined);
    return a !== undefined && b !== undefined ? [{ [key]: capped(a), [val]: capped(b) } as Record<K | V, string>] : [];
  });
}

function readFieldValue(value: unknown): UiFieldValue | undefined {
  if (typeof value === "string") return capped(value);
  if (typeof value === "boolean") return value;
  if (num(value) !== undefined) return value as number;
  if (Array.isArray(value) && value.every((item) => typeof item === "string")) return value as string[];
  return undefined;
}

const ALIGN: Readonly<Record<string, UiTableColumn["align"]>> = {
  start: "left",
  left: "left",
  center: "center",
  end: "right",
  right: "right",
};

/// What a node that cannot be drawn says instead.
const fallback = (id: string, what: string): UiFallbackNode => ({ type: "fallback", id, text: capped(what) });

type Budget = { left: number };

function readChildren(value: unknown, depth: number, budget: Budget, parent: string): UiNode[] {
  if (!Array.isArray(value)) return [];
  const out: UiNode[] = [];
  value.forEach((child, index) => {
    const node = readNode(child, depth + 1, budget, `${parent}.${index}`);
    if (node) out.push(node);
  });
  return out;
}

/// One node, or a fallback for what is unknown or malformed; undefined only past the node cap.
export function readNode(
  value: unknown,
  depth = 0,
  budget: Budget = { left: UI_SURFACE_CAPS.nodes },
  at = "root",
): UiNode | undefined {
  if (budget.left <= 0) return undefined;
  budget.left -= 1;
  if (!isRecord(value)) return fallback(at, "?");
  const id = str(value.id) || at;
  const a11y = readA11y(value.a11y);
  const base = { id, ...(a11y ? { a11y } : {}) };
  const type = str(value.type);
  if (depth >= UI_SURFACE_CAPS.depth && (type === "stack" || type === "card" || type === "list"))
    return { ...base, type: "fallback", text: "…" };
  switch (type) {
    case "text":
      return {
        ...base,
        type,
        text: text(value.text),
        style: oneOf(value.style, ["body", "heading", "caption", "code"] as const, "body"),
      };
    case "stack":
      return {
        ...base,
        type,
        axis: oneOf(value.axis, ["v", "h"] as const, "v"),
        children: readChildren(value.children, depth, budget, id),
      };
    case "card":
    case "list":
      return { ...base, type, children: readChildren(value.children, depth, budget, id) };
    case "divider":
      return { ...base, type };
    case "icon":
      return { ...base, type, name: text(value.name) };
    case "image":
      return { ...base, type, alt: text(value.alt) };
    case "button": {
      const action = readAction(value.action);
      return {
        ...base,
        type,
        label: text(value.label),
        ...(action ? { action } : {}),
        variant: oneOf(value.variant, ["primary", "secondary", "danger"] as const, "secondary"),
      };
    }
    case "field": {
      const input = optionalOneOf(value.input, ["text", "checkbox", "choice", "slider", "date"] as const);
      if (!input) return fallback(id, text(value.label) || "field");
      const fieldValue = readFieldValue(value.value);
      const options = readPairs(value.options, "value", "label");
      const min = num(value.min);
      const max = num(value.max);
      const bind = str(value.bind);
      return {
        ...base,
        type,
        label: text(value.label),
        input,
        ...(fieldValue !== undefined ? { value: fieldValue } : {}),
        ...(options.length ? { options } : {}),
        ...(value.multi === true ? { multi: true } : {}),
        ...(min !== undefined ? { min } : {}),
        ...(max !== undefined ? { max } : {}),
        ...(bind ? { bind } : {}),
        ...(value.secure === true ? { secure: true } : {}),
      };
    }
    case "approval": {
      const approve = readAction(value.approve);
      const deny = readAction(value.deny);
      const detail = str(value.detail);
      return {
        ...base,
        type,
        title: text(value.title),
        ...(detail ? { detail: capped(detail) } : {}),
        risk: oneOf(value.risk, ["low", "medium", "high"] as const, "medium"),
        facts: readPairs(value.facts, "label", "value"),
        ...(approve ? { approve } : {}),
        ...(deny ? { deny } : {}),
      };
    }
    case "review": {
      const submit = readAction(value.submit);
      const prompt = str(value.prompt);
      const bind = str(value.bind);
      const selected = Array.isArray(value.selected)
        ? value.selected.filter((id): id is string => typeof id === "string")
        : [];
      const options = Array.isArray(value.options)
        ? value.options.flatMap((option): UiReviewOption[] => {
            if (!isRecord(option)) return [];
            const optionId = str(option.id);
            if (!optionId) return [];
            const detail = str(option.detail);
            return [{ id: optionId, label: text(option.label), ...(detail ? { detail: capped(detail) } : {}) }];
          })
        : [];
      return {
        ...base,
        type,
        title: text(value.title),
        ...(prompt ? { prompt: capped(prompt) } : {}),
        options,
        ...(value.multi === true ? { multi: true } : {}),
        ...(submit ? { submit } : {}),
        ...(bind ? { bind } : {}),
        ...(selected.length ? { selected } : {}),
      };
    }
    case "table": {
      const columns = Array.isArray(value.columns)
        ? value.columns.flatMap((column): UiTableColumn[] => {
            if (!isRecord(column)) return [];
            const key = str(column.key) ?? "";
            // Rust writes `start` / `center` / `end` (logical, so a right-to-left page mirrors it).
            const align = ALIGN[str(column.align) ?? ""];
            return [{ key, label: text(column.label), ...(align ? { align } : {}) }];
          })
        : [];
      const allRows = Array.isArray(value.rows) ? value.rows : [];
      const rows = allRows
        .slice(0, UI_SURFACE_CAPS.tableRows)
        .map((row) =>
          Array.isArray(row) ? row.map((cell) => (typeof cell === "number" ? String(cell) : text(cell))) : [],
        );
      const truncated = value.truncated === true || allRows.length > UI_SURFACE_CAPS.tableRows;
      return { ...base, type, columns, rows, ...(truncated ? { truncated: true } : {}) };
    }
    case "chart": {
      let points = UI_SURFACE_CAPS.chartPoints;
      const series = Array.isArray(value.series)
        ? value.series.flatMap((entry, index) => {
            if (!isRecord(entry) || !Array.isArray(entry.points)) return [];
            const read = entry.points.flatMap((point): UiChartPoint[] => {
              if (!isRecord(point)) return [];
              const y = num(point.y);
              const x = typeof point.x === "number" ? point.x : str(point.x);
              return y !== undefined && x !== undefined ? [{ x: typeof x === "string" ? capped(x) : x, y }] : [];
            });
            const kept = read.slice(0, Math.max(0, points));
            points -= kept.length;
            return [{ name: str(entry.name) ? capped(entry.name as string) : `series ${index + 1}`, points: kept }];
          })
        : [];
      const yLabel = str(value.yLabel);
      return {
        ...base,
        type,
        kind: oneOf(value.kind, ["bar", "line", "pie"] as const, "bar"),
        series,
        ...(yLabel ? { yLabel: capped(yLabel) } : {}),
      };
    }
    case "progress": {
      const v = num(value.value);
      const max = num(value.max);
      return {
        ...base,
        type,
        label: text(value.label),
        ...(v !== undefined ? { value: v } : {}),
        ...(max !== undefined ? { max } : {}),
        state: oneOf(value.state, ["running", "done", "failed"] as const, "running"),
      };
    }
    case "fallback":
      return { ...base, type, text: text(value.text) };
    default:
      return { ...base, type: "fallback", text: capped(type ?? "?") };
  }
}

function readPending(value: unknown): UiSurfacePending | undefined {
  if (!isRecord(value)) return undefined;
  const requestId = str(value.requestId);
  const actionId = str(value.actionId);
  const summary = str(value.summary);
  if (!requestId || !actionId || !summary) return undefined;
  return {
    requestId,
    actionId,
    summary: capped(summary),
    sends: readPairs(value.sends, "label", "value"),
    target: text(value.target),
  };
}

/// A pending answer from `uiSurfaceAction` (Rust's reply), or undefined.
export const readUiSurfacePending = readPending;

/// The surface `value` holds, or undefined when it is not a `cmux.ui-surface/1` surface.
export function readUiSurface(value: unknown): UiSurface | undefined {
  if (!isRecord(value) || value.schema !== UI_SURFACE_SCHEMA) return undefined;
  const surfaceId = str(value.surfaceId);
  if (!surfaceId) return undefined;
  const source = isRecord(value.source) ? value.source : {};
  const status = oneOf(value.status, ["streaming", "ready", "error"] as const, "ready");
  const root = value.root === undefined || value.root === null ? undefined : readNode(value.root);
  const frame =
    isRecord(value.frame) && typeof value.frame.html === "string"
      ? {
          html: value.frame.html,
          ...(str(value.frame.csp) ? { csp: value.frame.csp as string } : {}),
          ...(num(value.frame.height) !== undefined ? { height: value.frame.height as number } : {}),
        }
      : null;
  const pending = readPending(value.pending) ?? null;
  const error = str(value.error);
  const title = str(value.title);
  const server = str(source.server);
  const tool = str(source.tool);
  const resourceUri = str(source.resourceUri);
  const catalogId = str(source.catalogId);
  return {
    schema: UI_SURFACE_SCHEMA,
    surfaceId,
    source: {
      kind: oneOf(source.kind, ["a2ui", "mcp-app"] as const, "a2ui"),
      ...(server ? { server: capped(server) } : {}),
      ...(tool ? { tool: capped(tool) } : {}),
      ...(resourceUri ? { resourceUri: capped(resourceUri) } : {}),
      ...(catalogId ? { catalogId: capped(catalogId) } : {}),
      ...(source.claimed === true ? { claimed: true } : {}),
    },
    status,
    ...(error ? { error: capped(error) } : {}),
    ...(title ? { title: capped(title) } : {}),
    ...(root ? { root } : {}),
    frame,
    pending,
  };
}

// ---------- values ----------

/// The value key a field or review is held under: its `bind`, else its id.
export const valueKey = (node: { id: string; bind?: string }) => node.bind ?? node.id;

/// The starting values every field and review in `root` holds (what Rust last sent), keyed by `bind`.
export function initialValues(root: UiNode | undefined): UiSurfaceValues {
  const values: UiSurfaceValues = {};
  const walk = (node: UiNode) => {
    if (node.type === "field" && node.value !== undefined) values[valueKey(node)] = node.value;
    if (node.type === "review" && node.selected)
      values[valueKey(node)] = node.multi ? node.selected : (node.selected[0] ?? "");
    if ("children" in node) node.children.forEach(walk);
  };
  if (root) walk(root);
  return values;
}

/// Every node in `root`, keyed by id: an update compares a node with the one it replaces.
export function nodesById(root: UiNode | undefined): Map<string, UiNode> {
  const map = new Map<string, UiNode>();
  const walk = (node: UiNode) => {
    map.set(node.id, node);
    if ("children" in node) node.children.forEach(walk);
  };
  if (root) walk(root);
  return map;
}

/// Structural equality of two nodes (Rust re-emits whole nodes; equal ones keep their React subtree).
export function sameNode(a: UiNode, b: UiNode): boolean {
  return a === b || signature(a) === signature(b);
}

const signatures = new WeakMap<UiNode, string>();
/// A node's whole JSON, once per node object (Rust sends a new tree per update; each node is read once).
function signature(node: UiNode): string {
  let known = signatures.get(node);
  if (known === undefined) {
    known = JSON.stringify(node);
    signatures.set(node, known);
  }
  return known;
}

/// The source line's words: "from quickstart · get-time", or the server alone.
export function sourceLine(source: UiSurfaceSource): string {
  return [source.server, source.tool].filter(Boolean).join(" · ");
}
