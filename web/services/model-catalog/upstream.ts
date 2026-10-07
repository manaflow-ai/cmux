// models.dev input: a lenient reader that keeps only the providers the
// overrides name and only the fields the catalog uses. models.dev may add,
// rename, or change the type of a field at any time; a field that does not
// pass its check is dropped, never passed through, so the served schema does
// not change with upstream.

import {
  CatalogSchemaError,
  MODEL_STATUSES,
  validateCost,
  validateDate,
  validateModalities,
  validateModelId,
  validateHarnessId,
  type CatalogCost,
  type CatalogModalities,
  type ModelStatus,
} from "./schema";

export const MODELS_DEV_URL = "https://models.dev/api.json";
/** models.dev's whole file is about 5 MB; refuse anything far above that. */
export const MAX_UPSTREAM_BYTES = 32 * 1024 * 1024;
export const UPSTREAM_TIMEOUT_MS = 20_000;

export interface UpstreamModel {
  id: string;
  name: string;
  family?: string;
  releaseDate?: string;
  lastUpdated?: string;
  knowledge?: string;
  contextWindow?: number;
  maxOutput?: number;
  cost?: CatalogCost;
  modalities?: CatalogModalities;
  reasoning?: boolean;
  toolCall?: boolean;
  attachment?: boolean;
  openWeights?: boolean;
  status?: ModelStatus;
}

export interface UpstreamProvider {
  id: string;
  name: string;
  models: Record<string, UpstreamModel>;
}

/** The part of models.dev the catalog reads. Also the shape of the bundled snapshot. */
export interface UpstreamSubset {
  fetchedAt: string;
  providers: Record<string, UpstreamProvider>;
}

function attempt<T>(read: () => T): T | undefined {
  try {
    return read();
  } catch (error) {
    if (error instanceof CatalogSchemaError) return undefined;
    throw error;
  }
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function shortText(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() && value.length <= 200 ? value.trim() : undefined;
}

function positiveInteger(value: unknown): number | undefined {
  return Number.isInteger(value) && (value as number) > 0 ? (value as number) : undefined;
}

function optionalBoolean(value: unknown): boolean | undefined {
  return typeof value === "boolean" ? value : undefined;
}

function upstreamCost(value: unknown): CatalogCost | undefined {
  if (!isObject(value)) return undefined;
  const cost = { input: value.input, output: value.output, cacheRead: value.cache_read, cacheWrite: value.cache_write };
  const present = Object.fromEntries(Object.entries(cost).filter(([, entry]) => entry !== undefined));
  return attempt(() => validateCost(present, "cost"));
}

function upstreamModalities(value: unknown): CatalogModalities | undefined {
  if (!isObject(value)) return undefined;
  // Drop modalities this schema does not know instead of the whole field.
  const known = (list: unknown) =>
    Array.isArray(list) ? [...new Set(list.filter((entry) => ["text", "image", "audio", "video", "pdf"].includes(entry)))] : list;
  return attempt(() => validateModalities({ input: known(value.input), output: known(value.output) }, "modalities"));
}

function withDefined<T extends object>(value: T): T {
  return Object.fromEntries(Object.entries(value).filter(([, entry]) => entry !== undefined)) as T;
}

/** One models.dev model, or undefined when it has no usable id. */
export function readUpstreamModel(key: string, value: unknown): UpstreamModel | undefined {
  if (!isObject(value)) return undefined;
  const id = attempt(() => validateModelId(typeof value.id === "string" ? value.id : key, "id"));
  if (!id) return undefined;
  const limit = isObject(value.limit) ? value.limit : {};
  const status = MODEL_STATUSES.find((entry) => entry === value.status);
  return withDefined({
    id,
    name: shortText(value.name) ?? id,
    family: shortText(value.family),
    releaseDate: attempt(() => validateDate(value.release_date, "release_date")),
    lastUpdated: attempt(() => validateDate(value.last_updated, "last_updated")),
    knowledge: attempt(() => validateDate(value.knowledge, "knowledge")),
    contextWindow: positiveInteger(limit.context),
    maxOutput: positiveInteger(limit.output),
    cost: upstreamCost(value.cost),
    modalities: upstreamModalities(value.modalities),
    reasoning: optionalBoolean(value.reasoning),
    toolCall: optionalBoolean(value.tool_call),
    attachment: optionalBoolean(value.attachment),
    openWeights: optionalBoolean(value.open_weights),
    status,
  });
}

function readProvider(id: string, value: unknown): UpstreamProvider | undefined {
  if (!isObject(value) || !isObject(value.models)) return undefined;
  const models: Record<string, UpstreamModel> = {};
  for (const [key, entry] of Object.entries(value.models)) {
    const model = readUpstreamModel(key, entry);
    if (model && !models[model.id]) models[model.id] = model;
  }
  return { id, name: shortText(value.name) ?? id, models };
}

/**
 * The providers in `providerIds` from a models.dev document. Throws when the
 * document is not an object of providers or names none of them: that is an
 * upstream outage or format break, and the caller keeps its last good copy.
 */
export function selectUpstream(document: unknown, providerIds: readonly string[], fetchedAt: string): UpstreamSubset {
  if (!isObject(document)) throw new Error("models.dev returned a non-object document");
  const providers: Record<string, UpstreamProvider> = {};
  for (const id of providerIds) {
    if (!attempt(() => validateHarnessId(id, "provider"))) continue;
    const provider = readProvider(id, document[id]);
    if (provider) providers[id] = provider;
  }
  if (Object.keys(providers).length === 0) throw new Error("models.dev named none of the curated providers");
  return { fetchedAt, providers };
}

/** Re-reads a stored subset (runtime cache or snapshot) through the same lenient reader. */
export function readStoredSubset(value: unknown): UpstreamSubset | undefined {
  if (!isObject(value) || typeof value.fetchedAt !== "string" || !isObject(value.providers)) return undefined;
  if (Number.isNaN(Date.parse(value.fetchedAt))) return undefined;
  const providers: Record<string, UpstreamProvider> = {};
  for (const [id, entry] of Object.entries(value.providers)) {
    if (!isObject(entry) || !isObject(entry.models)) continue;
    const models: Record<string, UpstreamModel> = {};
    for (const [key, model] of Object.entries(entry.models)) {
      const read = readStoredModel(key, model);
      if (read) models[read.id] = read;
    }
    providers[id] = { id, name: shortText(entry.name) ?? id, models };
  }
  return Object.keys(providers).length > 0 ? { fetchedAt: value.fetchedAt, providers } : undefined;
}

/** A stored model uses the subset's camelCase names; map it back to the models.dev names and re-read it. */
function readStoredModel(key: string, value: unknown): UpstreamModel | undefined {
  if (!isObject(value)) return undefined;
  const cost = isObject(value.cost)
    ? { input: value.cost.input, output: value.cost.output, cache_read: value.cost.cacheRead, cache_write: value.cost.cacheWrite }
    : undefined;
  return readUpstreamModel(key, {
    ...value,
    release_date: value.releaseDate,
    last_updated: value.lastUpdated,
    limit: { context: value.contextWindow, output: value.maxOutput },
    cost,
    tool_call: value.toolCall,
    open_weights: value.openWeights,
  });
}

async function readLimitedBody(response: Response, maxBytes: number): Promise<string> {
  const declared = Number(response.headers.get("content-length") ?? "0");
  if (declared > maxBytes) throw new Error(`models.dev body is ${declared} bytes, above ${maxBytes}`);
  if (!response.body) throw new Error("models.dev returned no body");
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel();
      throw new Error(`models.dev body is above ${maxBytes} bytes`);
    }
    chunks.push(value);
  }
  return Buffer.concat(chunks).toString("utf8");
}

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

/** Fetches models.dev once (no Next fetch cache: the file is above its 2 MB limit). */
export async function fetchUpstream(
  providerIds: readonly string[],
  options: { fetch?: FetchLike; now?: () => Date; timeoutMs?: number } = {},
): Promise<UpstreamSubset> {
  const doFetch = options.fetch ?? fetch;
  const response = await doFetch(MODELS_DEV_URL, {
    cache: "no-store",
    headers: { Accept: "application/json", "User-Agent": "cmux-model-catalog/1 (+https://cmux.com)" },
    redirect: "error",
    signal: AbortSignal.timeout(options.timeoutMs ?? UPSTREAM_TIMEOUT_MS),
  });
  if (!response.ok) throw new Error(`models.dev answered ${response.status}`);
  const body = await readLimitedBody(response, MAX_UPSTREAM_BYTES);
  const fetchedAt = (options.now?.() ?? new Date()).toISOString();
  return selectUpstream(JSON.parse(body), providerIds, fetchedAt);
}
