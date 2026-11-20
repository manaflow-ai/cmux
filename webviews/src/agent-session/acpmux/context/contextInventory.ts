// A chat's effective prompt context as acpmux reports it (`_acpmux/context`, acpmux
// context_inventory.rs), read for the Context screen (ContextScreen.tsx). acpmux returns the text
// only of what cmux adds (and of a verified local preset prompt); the harness's own prompt, its memory
// files, MCP tools and skills come as token counts the harness measured. Everything here is parsed
// defensively: a field of the wrong type is dropped, never thrown on.

/// One part of the context. `text` is set only for text cmux owns.
export type InventoryPart = {
  id: string;
  source: string;
  label: string;
  tokens: number;
  included: boolean;
  editable: boolean;
  /// `measured` (the harness counted it), `estimated` (cmux did), `unavailable` (not reported).
  measurement: "measured" | "estimated" | "unavailable";
  channel?: string;
  text?: string;
};

/// A preset prompt acpmux lets this chat's folder override (`overrides.parts`).
export type PromptOverride = { label: string; defaultText: string; user?: string; project?: string };

export type Inventory = {
  parts: InventoryPart[];
  /// The harness's total when it reported one, else cmux's own estimate.
  totalTokens: number;
  providerTotalTokens?: number;
  cmuxTokens: number;
  maxTokens?: number;
  /// False over a remote connection, which gets counts only.
  canEdit: boolean;
  /// cmux's default first-turn guidance (agent_tools.rs CONCURRENT_WORK_RULE) and the saved
  /// replacements: `user` for every chat, `project` for chats in `cwd`. `undefined` is none saved;
  /// an empty string turns the guidance off.
  defaultText?: string;
  user?: string;
  project?: string;
  cwd: string;
  prompts: Record<string, PromptOverride>;
};

/// The groups the screen lists, in order.
export type GroupId = "cmux" | "harness" | "memory" | "mcp" | "skill";
export const GROUPS: readonly GroupId[] = ["cmux", "harness", "memory", "mcp", "skill"];

const record = (value: unknown): Record<string, unknown> | undefined =>
  value !== null && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
const text = (value: unknown) => (typeof value === "string" ? value : undefined);
const count = (value: unknown) => (typeof value === "number" && Number.isFinite(value) ? Math.max(0, value) : 0);
const optionalCount = (value: unknown) =>
  typeof value === "number" && Number.isFinite(value) ? Math.max(0, value) : undefined;
const MEASUREMENTS = new Set(["measured", "estimated", "unavailable"]);

function part(value: unknown): InventoryPart | undefined {
  const row = record(value);
  const id = text(row?.id);
  if (!row || !id) return undefined;
  const measurement = text(row.measurement);
  const channel = text(row.channel);
  const body = text(row.text);
  return {
    id,
    source: text(row.source) ?? "",
    label: text(row.label) || id,
    tokens: count(row.tokens),
    included: row.included !== false,
    editable: row.editable === true,
    measurement:
      measurement && MEASUREMENTS.has(measurement) ? (measurement as InventoryPart["measurement"]) : "measured",
    ...(channel ? { channel } : {}),
    ...(body !== undefined ? { text: body } : {}),
  };
}

/// The inventory in `value`, or none when it is not one.
export function parseInventory(value: unknown): Inventory | undefined {
  const root = record(value);
  if (!root || !Array.isArray(root.parts)) return undefined;
  const overrides = record(root.overrides) ?? {};
  const prompts: Record<string, PromptOverride> = {};
  for (const [id, raw] of Object.entries(record(overrides.parts) ?? {})) {
    const prompt = record(raw);
    const defaultText = text(prompt?.defaultText);
    if (!prompt || defaultText === undefined) continue;
    const user = text(prompt.user);
    const project = text(prompt.project);
    prompts[id] = {
      label: text(prompt.label) || id,
      defaultText,
      ...(user !== undefined ? { user } : {}),
      ...(project !== undefined ? { project } : {}),
    };
  }
  const defaultText = text(overrides.defaultText);
  const user = text(overrides.user);
  const project = text(overrides.project);
  const providerTotalTokens = optionalCount(root.providerTotalTokens);
  const maxTokens = optionalCount(root.maxTokens);
  return {
    parts: root.parts.map(part).filter((p): p is InventoryPart => p !== undefined),
    totalTokens: count(root.totalTokens),
    ...(providerTotalTokens !== undefined ? { providerTotalTokens } : {}),
    cmuxTokens: count(root.cmuxTokens),
    ...(maxTokens !== undefined ? { maxTokens } : {}),
    canEdit: root.canEditOverrides === true,
    ...(defaultText !== undefined ? { defaultText } : {}),
    ...(user !== undefined ? { user } : {}),
    ...(project !== undefined ? { project } : {}),
    cwd: text(overrides.cwd) ?? "",
    prompts,
  };
}

/// The group a part is listed under: everything cmux adds (its guidance, MCP instructions, a moved
/// folder's instructions, a preset prompt), then the harness's own categories and its detail lists.
export function groupOf(part: InventoryPart): GroupId {
  if (part.source.startsWith("cmux-")) return "cmux";
  if (part.source === "memory") return "memory";
  if (part.source === "mcp") return "mcp";
  if (part.source === "skill") return "skill";
  return "harness";
}

/// The parts of each group that have something to show, in the order acpmux sent them. A cmux part
/// with no text and no tokens (a server acpmux names but cannot measure) is still listed: it says
/// what the chat was given.
export function grouped(inventory: Inventory): { id: GroupId; parts: InventoryPart[] }[] {
  return GROUPS.map((id) => ({ id, parts: inventory.parts.filter((p) => groupOf(p) === id) })).filter(
    (group) => group.parts.length > 0,
  );
}

/// What the guidance editor starts from in `scope`: that scope's saved text, else what a new chat
/// there gets today (a folder's chat falls back to the text for every chat, then to cmux's default).
export function guidanceDraft(inventory: Inventory, scope: "user" | "project"): string {
  if (scope === "project" && inventory.project !== undefined) return inventory.project;
  return inventory.user ?? inventory.defaultText ?? "";
}
