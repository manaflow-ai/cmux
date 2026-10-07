// The served model catalog (`GET /api/models/v1`) and its strict validator.
//
// `version` is the major schema version. A client refuses a higher major
// version and keeps the copy it has. Fields added inside version 1 are
// optional, so an older client that ignores unknown fields stays correct.

export const MODEL_CATALOG_VERSION = 1;
/** The served body must stay well under the 2 MB limit every client enforces. */
export const MAX_CATALOG_BYTES = 1_000_000;

export const MODALITIES = ["text", "image", "audio", "video", "pdf"] as const;
export type Modality = (typeof MODALITIES)[number];
export const MODEL_STATUSES = ["alpha", "beta", "deprecated"] as const;
export type ModelStatus = (typeof MODEL_STATUSES)[number];
/** Icons a client draws itself. The catalog never carries an icon file or URL. */
export const HARNESS_ICONS = ["claude", "openai", "codex", "opencode", "pi", "gemini", "terminal", "generic"] as const;
export type HarnessIcon = (typeof HARNESS_ICONS)[number];
/** Hosts a `docsUrl` may point at. Clients apply their own allowlist too. */
export const DOCS_URL_HOSTS = [
  "aider.chat",
  "cmux.com",
  "developers.openai.com",
  "docs.anthropic.com",
  "docs.claude.com",
  "github.com",
  "opencode.ai",
] as const;

/** USD per million tokens. */
export interface CatalogCost {
  input: number;
  output: number;
  cacheRead?: number;
  cacheWrite?: number;
}

export interface CatalogModalities {
  input: Modality[];
  output: Modality[];
}

export interface CatalogModel {
  /** The id the harness takes (`--model`, ACP `session/set_model`). */
  id: string;
  name: string;
  /** models.dev provider id, for example `anthropic`. */
  provider: string;
  providerName: string;
  shortName?: string;
  family?: string;
  default?: true;
  recommended?: true;
  contextWindow?: number;
  maxOutput?: number;
  cost?: CatalogCost;
  modalities?: CatalogModalities;
  reasoning?: boolean;
  toolCall?: boolean;
  attachment?: boolean;
  openWeights?: boolean;
  efforts?: string[];
  defaultEffort?: string;
  fast?: boolean;
  /** YYYY-MM-DD or YYYY-MM. */
  releaseDate?: string;
  knowledge?: string;
  /** The lowest harness version that accepts this model. */
  minVersion?: string;
  status?: ModelStatus;
}

export interface CatalogHarness {
  id: string;
  name: string;
  icon?: HarnessIcon;
  docsUrl?: string;
  /** The lowest harness version cmux supports. */
  minVersion?: string;
  /** The model a new chat starts with. Unset: the harness's own default. */
  defaultModel?: string;
  models: CatalogModel[];
}

export interface ModelCatalog {
  version: typeof MODEL_CATALOG_VERSION;
  /** The newest change in the content: the overrides date or a model's models.dev date. */
  updatedAt: string;
  harnesses: CatalogHarness[];
}

const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:/@[\]+-]{0,199}$/;
const HARNESS_ID_PATTERN = /^[a-z0-9][a-z0-9-]{0,63}$/;
const VERSION_PATTERN = /^\d{1,9}(\.\d{1,9}){0,3}$/;
const DATE_PATTERN = /^\d{4}-\d{2}(-\d{2})?$/;
const EFFORT_PATTERN = /^[a-z][a-z0-9-]{0,31}$/;
const MAX_TEXT = 200;
const MAX_HARNESSES = 64;
const MAX_MODELS_PER_HARNESS = 1_000;

export class CatalogSchemaError extends Error {}

function fail(path: string, message: string): never {
  throw new CatalogSchemaError(`${path} ${message}`);
}

export function record(input: unknown, path: string): Record<string, unknown> {
  if (typeof input !== "object" || input === null || Array.isArray(input)) fail(path, "must be an object");
  return input as Record<string, unknown>;
}

export function text(input: unknown, path: string, max = MAX_TEXT): string {
  if (typeof input !== "string" || input.trim().length === 0) fail(path, "must be a nonempty string");
  if (input.length > max) fail(path, `must be at most ${max} characters`);
  return input;
}

function matching(input: unknown, pattern: RegExp, path: string): string {
  const value = text(input, path);
  if (!pattern.test(value)) fail(path, `has an invalid format: ${JSON.stringify(value).slice(0, 80)}`);
  return value;
}

function onlyKeys(value: Record<string, unknown>, allowed: readonly string[], path: string): void {
  for (const key of Object.keys(value)) {
    if (!allowed.includes(key)) fail(`${path}.${key}`, "is not a known field");
  }
}

function nonNegative(input: unknown, path: string): number {
  if (typeof input !== "number" || !Number.isFinite(input) || input < 0) fail(path, "must be a nonnegative number");
  return input;
}

function positiveInteger(input: unknown, path: string): number {
  if (!Number.isInteger(input) || (input as number) <= 0) fail(path, "must be a positive integer");
  return input as number;
}

function bool(input: unknown, path: string): boolean {
  if (typeof input !== "boolean") fail(path, "must be a boolean");
  return input;
}

function oneOf<T extends string>(input: unknown, values: readonly T[], path: string): T {
  if (typeof input !== "string" || !values.includes(input as T)) fail(path, `must be one of ${values.join(", ")}`);
  return input as T;
}

export function validateCost(input: unknown, path: string): CatalogCost {
  const value = record(input, path);
  onlyKeys(value, ["input", "output", "cacheRead", "cacheWrite"], path);
  const cost: CatalogCost = {
    input: nonNegative(value.input, `${path}.input`),
    output: nonNegative(value.output, `${path}.output`),
  };
  if (value.cacheRead !== undefined) cost.cacheRead = nonNegative(value.cacheRead, `${path}.cacheRead`);
  if (value.cacheWrite !== undefined) cost.cacheWrite = nonNegative(value.cacheWrite, `${path}.cacheWrite`);
  return cost;
}

function modalityList(input: unknown, path: string): Modality[] {
  if (!Array.isArray(input) || input.length === 0) fail(path, "must be a nonempty array");
  const list = input.map((entry, index) => oneOf(entry, MODALITIES, `${path}[${index}]`));
  if (new Set(list).size !== list.length) fail(path, "has duplicates");
  return list;
}

export function validateModalities(input: unknown, path: string): CatalogModalities {
  const value = record(input, path);
  onlyKeys(value, ["input", "output"], path);
  return { input: modalityList(value.input, `${path}.input`), output: modalityList(value.output, `${path}.output`) };
}

export function validateEfforts(input: unknown, path: string): string[] {
  if (!Array.isArray(input) || input.length === 0) fail(path, "must be a nonempty array");
  const list = input.map((entry, index) => matching(entry, EFFORT_PATTERN, `${path}[${index}]`));
  if (new Set(list).size !== list.length) fail(path, "has duplicates");
  return list;
}

export function validateDocsUrl(input: unknown, path: string): string {
  const value = text(input, path, 500);
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    fail(path, "must be an absolute URL");
  }
  if (url.protocol !== "https:") fail(path, "must use https");
  if (url.username || url.password) fail(path, "must not carry credentials");
  if (!(DOCS_URL_HOSTS as readonly string[]).includes(url.hostname)) fail(path, `host ${url.hostname} is not allowed`);
  return value;
}

export const validateVersionString = (input: unknown, path: string) => matching(input, VERSION_PATTERN, path);
export const validateDate = (input: unknown, path: string) => matching(input, DATE_PATTERN, path);
export const validateModelId = (input: unknown, path: string) => matching(input, ID_PATTERN, path);
export const validateHarnessId = (input: unknown, path: string) => matching(input, HARNESS_ID_PATTERN, path);

const MODEL_KEYS = [
  "id", "name", "provider", "providerName", "shortName", "family", "default", "recommended",
  "contextWindow", "maxOutput", "cost", "modalities", "reasoning", "toolCall", "attachment",
  "openWeights", "efforts", "defaultEffort", "fast", "releaseDate", "knowledge", "minVersion", "status",
] as const;

type Check = (input: unknown, path: string) => unknown;
const trueFlag: Check = (input, path) => {
  if (input !== true) fail(path, "must be true when present");
  return true;
};
const OPTIONAL_MODEL_FIELDS: Record<string, Check> = {
  shortName: text,
  family: text,
  default: trueFlag,
  recommended: trueFlag,
  contextWindow: positiveInteger,
  maxOutput: positiveInteger,
  cost: validateCost,
  modalities: validateModalities,
  reasoning: bool,
  toolCall: bool,
  attachment: bool,
  openWeights: bool,
  efforts: validateEfforts,
  defaultEffort: (input, path) => matching(input, EFFORT_PATTERN, path),
  fast: bool,
  releaseDate: validateDate,
  knowledge: validateDate,
  minVersion: validateVersionString,
  status: (input, path) => oneOf(input, MODEL_STATUSES, path),
};

export function validateModel(input: unknown, path: string): CatalogModel {
  const value = record(input, path);
  onlyKeys(value, MODEL_KEYS, path);
  const model: Record<string, unknown> = {
    id: validateModelId(value.id, `${path}.id`),
    name: text(value.name, `${path}.name`),
    provider: matching(value.provider, HARNESS_ID_PATTERN, `${path}.provider`),
    providerName: text(value.providerName, `${path}.providerName`),
  };
  for (const [key, check] of Object.entries(OPTIONAL_MODEL_FIELDS)) {
    if (value[key] !== undefined) model[key] = check(value[key], `${path}.${key}`);
  }
  const efforts = model.efforts as string[] | undefined;
  if (model.defaultEffort !== undefined && !efforts?.includes(model.defaultEffort as string)) {
    fail(`${path}.defaultEffort`, "must be one of its efforts");
  }
  return model as unknown as CatalogModel;
}

function validateModels(input: unknown, path: string): CatalogModel[] {
  if (!Array.isArray(input)) fail(path, "must be an array");
  if (input.length > MAX_MODELS_PER_HARNESS) fail(path, `must have at most ${MAX_MODELS_PER_HARNESS} entries`);
  const models = input.map((entry, index) => validateModel(entry, `${path}[${index}]`));
  const ids = new Set<string>();
  for (const model of models) {
    if (ids.has(model.id)) fail(path, `has duplicate model id ${model.id}`);
    ids.add(model.id);
  }
  return models;
}

const HARNESS_KEYS = ["id", "name", "icon", "docsUrl", "minVersion", "defaultModel", "models"] as const;

export function validateHarness(input: unknown, path: string): CatalogHarness {
  const value = record(input, path);
  onlyKeys(value, HARNESS_KEYS, path);
  const harness: CatalogHarness = {
    id: validateHarnessId(value.id, `${path}.id`),
    name: text(value.name, `${path}.name`),
    models: [],
  };
  if (value.icon !== undefined) harness.icon = oneOf(value.icon, HARNESS_ICONS, `${path}.icon`);
  if (value.docsUrl !== undefined) harness.docsUrl = validateDocsUrl(value.docsUrl, `${path}.docsUrl`);
  if (value.minVersion !== undefined) harness.minVersion = validateVersionString(value.minVersion, `${path}.minVersion`);
  harness.models = validateModels(value.models, `${path}.models`);
  if (value.defaultModel !== undefined) {
    const id = validateModelId(value.defaultModel, `${path}.defaultModel`);
    if (!harness.models.some((model) => model.id === id)) fail(`${path}.defaultModel`, "must name one of its models");
    harness.defaultModel = id;
  }
  // Keep the key order stable so the content hash (ETag) depends only on the data.
  return {
    id: harness.id,
    name: harness.name,
    ...(harness.icon ? { icon: harness.icon } : {}),
    ...(harness.docsUrl ? { docsUrl: harness.docsUrl } : {}),
    ...(harness.minVersion ? { minVersion: harness.minVersion } : {}),
    ...(harness.defaultModel ? { defaultModel: harness.defaultModel } : {}),
    models: harness.models,
  };
}

/** Validates a complete catalog and its serialized size. Throws CatalogSchemaError. */
export function validateCatalog(input: unknown): ModelCatalog {
  const value = record(input, "catalog");
  onlyKeys(value, ["version", "updatedAt", "harnesses"], "catalog");
  if (value.version !== MODEL_CATALOG_VERSION) fail("catalog.version", `must be ${MODEL_CATALOG_VERSION}`);
  const updatedAt = text(value.updatedAt, "catalog.updatedAt");
  if (Number.isNaN(Date.parse(updatedAt))) fail("catalog.updatedAt", "must be an ISO-8601 timestamp");
  if (!Array.isArray(value.harnesses) || value.harnesses.length === 0) fail("catalog.harnesses", "must be a nonempty array");
  if (value.harnesses.length > MAX_HARNESSES) fail("catalog.harnesses", `must have at most ${MAX_HARNESSES} entries`);
  const harnesses = value.harnesses.map((entry, index) => validateHarness(entry, `catalog.harnesses[${index}]`));
  const ids = new Set<string>();
  for (const harness of harnesses) {
    if (ids.has(harness.id)) fail("catalog.harnesses", `has duplicate harness id ${harness.id}`);
    ids.add(harness.id);
  }
  const catalog: ModelCatalog = { version: MODEL_CATALOG_VERSION, updatedAt, harnesses };
  const bytes = Buffer.byteLength(JSON.stringify(catalog));
  if (bytes > MAX_CATALOG_BYTES) fail("catalog", `is ${bytes} bytes, above the ${MAX_CATALOG_BYTES} byte limit`);
  return catalog;
}
