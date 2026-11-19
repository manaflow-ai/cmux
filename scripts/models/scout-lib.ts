// The model scout's pure parts (scripts/models/scout.ts runs them; scout-lib.test.ts tests them).
// User 2026-11-19 (chat 40603): "a live models backend that we control and an automation that will
// keep adding new models".

import type { ModelCatalog } from "../../web/services/model-catalog/types";

/** The catalog without its timestamps and server-only fields: two catalogs with the same models compare equal. */
/** Harnesses whose served copy has a killed model (the server moved their default off it). */
export function killedHarnesses(doc: Pick<ModelCatalog, "harnesses"> | null): Set<string> {
  return new Set((doc?.harnesses ?? []).filter((h) => h.models.some((m) => m.status === "disabled")).map((h) => h.id));
}

/** Compare two catalogs with the same `killed` set (killedHarnesses of the served one). */
export function catalogContent(doc: Pick<ModelCatalog, "harnesses" | "models" | "providers">, killed: ReadonlySet<string> = new Set()): string {
  const sort = (input: unknown): unknown => {
    if (Array.isArray(input)) return input.map(sort);
    if (input && typeof input === "object") return Object.fromEntries(Object.keys(input).sort().map((k) => [k, sort((input as Record<string, unknown>)[k])]));
    return input;
  };
  // "cmux" is the router harness cloud-api adds itself; a status and reason from the kill switch are the server's too.
  const clientOnly = (m: ModelCatalog["harnesses"][number]["models"][number]) => {
    const { statusReason: _reason, ...rest } = m;
    if (rest.status !== "disabled") return rest;
    const { status: _status, ...live } = rest;
    return live;
  };
  // The server also moves defaultModel off a killed model: a harness with a killed model compares without it.
  const harnesses = doc.harnesses
    .filter((h) => h.id !== "cmux")
    .map(({ defaultModel, ...h }) => ({ ...h, ...(killed.has(h.id) ? {} : { defaultModel }), models: h.models.map(clientOnly) }));
  return JSON.stringify(sort({ harnesses, models: doc.models, providers: doc.providers }));
}

/**
 * The served catalog without what cloud-api adds on its own: `models` entries for router models the
 * feed does not describe (the server fills them from the router catalog). Compare this with `next`.
 */
export function withoutServerAdditions(served: ModelCatalog, next: Pick<ModelCatalog, "models">): ModelCatalog {
  const router = new Set((served.harnesses.find((h) => h.id === "cmux")?.models ?? []).map((m) => m.id));
  const models = Object.fromEntries(Object.entries(served.models ?? {}).filter(([id]) => !router.has(id) || id in next.models));
  return { ...served, models };
}

export interface HarnessDiff {
  readonly added: Array<string>;
  readonly removed: Array<string>;
}

/** Models per harness that `next` lists and `prev` does not, and the other way round ("harness:model"). */
export function diffCatalogs(prev: Pick<ModelCatalog, "harnesses"> | null, next: Pick<ModelCatalog, "harnesses">): HarnessDiff {
  const ids = (doc: Pick<ModelCatalog, "harnesses"> | null) => new Set((doc?.harnesses ?? []).filter((h) => h.id !== "cmux").flatMap((h) => h.models.map((m) => `${h.id}:${m.id}`)));
  const before = ids(prev);
  const after = ids(next);
  return { added: [...after].filter((id) => !before.has(id)).sort(), removed: [...before].filter((id) => !after.has(id)).sort() };
}

/** A Vertex publisher model that could be a chat model for an agent (not image, speech, embedding or live audio). */
export function isChatCandidate(id: string): boolean {
  if (!id.startsWith("gemini-")) return false;
  return !/(embedding|tts|image|transcribe|live|native-audio|translate|omni|nano-banana|computer-use|-exp-|customtools)/.test(id) && !/-\d{3}$/.test(id) && !/preview-\d\d-\d\d$/.test(id);
}

export interface FeedPrice {
  readonly input: number;
  readonly output: number;
  readonly cacheRead?: number;
  readonly context?: number;
  readonly maxOutput?: number;
  readonly toolCall: boolean;
  readonly name: string;
  readonly releaseDate?: string;
}

/** What models.dev says about a Google model (google-vertex first: our route is Vertex). */
export function feedPrice(feed: Record<string, any>, id: string): FeedPrice | null {
  const m = feed["google-vertex"]?.models?.[id] ?? feed.google?.models?.[id];
  if (!m || typeof m.cost?.input !== "number" || typeof m.cost?.output !== "number") return null;
  return {
    input: m.cost.input,
    output: m.cost.output,
    ...(typeof m.cost.cache_read === "number" ? { cacheRead: m.cost.cache_read } : {}),
    ...(typeof m.limit?.context === "number" ? { context: m.limit.context } : {}),
    ...(typeof m.limit?.output === "number" ? { maxOutput: m.limit.output } : {}),
    toolCall: m.tool_call === true,
    name: typeof m.name === "string" ? m.name : id,
    ...(typeof m.release_date === "string" ? { releaseDate: m.release_date } : {}),
  };
}

export interface ScoutState {
  /** Vertex ids already seen; only an id that appears after the first run counts as new. */
  readonly seenVertex: Array<string>;
  /** Model ids a router PR was opened for, so a later run does not open another. */
  readonly proposed: Array<string>;
}

export const EMPTY_STATE: ScoutState = { seenVertex: [], proposed: [] };

/** On the first run (no state), a model released this many days ago or less still counts as new. */
export const FIRST_RUN_WINDOW_DAYS = 14;

/**
 * New Vertex models this run must act on: chat candidates that are neither seen before nor already
 * on the router. The first run (no state) has no "before": it takes the models released in the last
 * FIRST_RUN_WINDOW_DAYS (models.dev release dates) as new, and every older one as known.
 */
export function newVertexModels(vertexIds: ReadonlyArray<string>, routerIds: ReadonlyArray<string>, state: ScoutState | null, releaseDate: (id: string) => string | undefined = () => undefined, now = new Date()): Array<string> {
  const routed = new Set(routerIds);
  const cutoff = new Date(now.getTime() - FIRST_RUN_WINDOW_DAYS * 86_400_000).toISOString().slice(0, 10);
  const seen = new Set(state?.seenVertex ?? []);
  const fresh = (id: string) => (state ? !seen.has(id) : (releaseDate(id) ?? "") >= cutoff);
  return vertexIds.filter((id) => isChatCandidate(id) && fresh(id) && !routed.has(`google/${id}`)).sort();
}

/** The router catalog entry (backend/apps/api/src/inference/catalog.ts) for a Vertex model, as TypeScript text. */
export function routerEntry(id: string, price: FeedPrice, today: string): string {
  const context = price.context ?? 1_048_576;
  const maxOutput = price.maxOutput ?? 65_536;
  const num = (n: number) => (Number.isInteger(n) && n >= 10_000 ? n.toLocaleString("en-US").replace(/,/g, "_") : String(n));
  return [
    "  {",
    `    // ${price.name} (Google${price.releaseDate ? `, ${price.releaseDate}` : ""}): proposed by the model scout (scripts/models/scout.ts) on ${today}.`,
    `    // It answered a tool-call smoke turn on our Vertex AI (global). List price from models.dev; check it before merging.`,
    `    id: "google/${id}",`,
    `    name: ${JSON.stringify(price.name)},`,
    `    card: { input: ${price.input}, output: ${price.output} },`,
    `    context: ${num(context)},`,
    `    maxOutput: ${num(maxOutput)},`,
    `    defaultMaxTokens: ${num(Math.min(16_384, maxOutput))},`,
    `    tools: true,`,
    `    routes: [{ provider: "vertex", id: "google/${id}", list: { input: ${price.input}, output: ${price.output} } }]`,
    "  },",
  ].join("\n");
}

export const SCOUT_MARKER = "  // models-scout: new Vertex models go above this line.";

/** catalog.ts with `entry` inserted above the scout marker; null when the marker is missing or the id is already there. */
export function insertRouterEntry(source: string, id: string, entry: string): string | null {
  if (source.includes(`id: "google/${id}"`)) return null;
  const at = source.indexOf(SCOUT_MARKER);
  if (at < 0) return null;
  return source.slice(0, at) + entry + "\n" + source.slice(at);
}

/** The staging allowlist with `model` appended (wrangler.jsonc, env.staging only). Production stays a human's call. */
export function addToStagingAllowlist(wrangler: string, model: string): string | null {
  const staging = wrangler.indexOf('"ENVIRONMENT": "staging"');
  if (staging < 0) return null;
  const key = '"INFERENCE_MODEL_ALLOWLIST": "';
  const at = wrangler.indexOf(key, staging);
  const lineEnd = wrangler.indexOf("\n", staging);
  if (at < 0 || at > lineEnd) return null;
  const start = at + key.length;
  const end = wrangler.indexOf('"', start);
  const list = wrangler.slice(start, end).split(",").filter(Boolean);
  if (list.includes(model)) return null;
  return wrangler.slice(0, start) + [...list, model].join(",") + wrangler.slice(end);
}

export interface SmokeResult {
  readonly model: string;
  readonly ok: boolean;
  readonly toolCall: boolean;
  readonly status: number;
  readonly ms: number;
  readonly error?: string;
}

/** A chat/completions reply passes the smoke turn when it is 200 and called the ping tool (or, without tools, said something). */
export function judgeSmoke(model: string, status: number, body: any, ms: number, wantTool: boolean): SmokeResult {
  const message = body?.choices?.[0]?.message;
  const toolCall = Array.isArray(message?.tool_calls) && message.tool_calls.some((c: any) => c?.function?.name === "ping");
  const said = typeof message?.content === "string" && message.content.trim().length > 0;
  const ok = status === 200 && (wantTool ? toolCall : toolCall || said);
  const error = ok ? undefined : status !== 200 ? `HTTP ${status}: ${String(body?.error?.message ?? body?.error ?? "").slice(0, 200)}` : wantTool ? "no ping tool call" : "empty reply";
  return { model, ok, toolCall, status, ms, ...(error ? { error } : {}) };
}

export const PING_TOOL = {
  type: "function",
  function: { name: "ping", description: "Answer a health check.", parameters: { type: "object", properties: { n: { type: "integer" } }, required: ["n"] } },
};

export const smokeBody = (model: string) => ({
  model,
  max_tokens: 512,
  tools: [PING_TOOL],
  tool_choice: "required",
  messages: [{ role: "user", content: "Health check: call the ping tool with n = 1. Do nothing else." }],
});
