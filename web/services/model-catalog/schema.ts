// The strict check of a model catalog (types.ts, schemaVersion 1) before it is
// served, cached or bundled. acpmux applies the same rules (src/catalog/schema.rs).
//
// `schemaVersion` is the major version: a client refuses a higher one and keeps
// the copy it has. Fields added inside version 1 are optional, so an older
// client that ignores unknown fields stays correct.

import type { CatalogHarness, HarnessModel, ModelCatalog, ModelInfo } from "./types";

export const SCHEMA_VERSION = 1;
/** The served body must stay well under the 2 MB limit every client enforces. */
export const MAX_CATALOG_BYTES = 1_000_000;
/** Hosts a harness `docsUrl` may point at. acpmux drops any other URL. */
export const DOCS_URL_HOSTS = [
  "aider.chat",
  "cmux.com",
  "developers.openai.com",
  "docs.anthropic.com",
  "docs.claude.com",
  "github.com",
  "opencode.ai",
  "vercel.com",
] as const;

const EFFORTS = ["none", "minimal", "low", "medium", "high", "xhigh", "max"];
const STATUSES = ["preview", "deprecated"];
const MODALITIES = ["text", "image", "pdf", "audio", "video"];
const ID = /^[A-Za-z0-9][A-Za-z0-9._:/@[\]+-]{0,199}$/;
const SLUG = /^[a-z0-9][a-z0-9-]{0,63}$/;
const MAX_TEXT = 200;
const MAX_HARNESSES = 64;
const MAX_MODELS = 2_000;

export class CatalogSchemaError extends Error {}

function fail(path: string, message: string): never {
  throw new CatalogSchemaError(`${path} ${message}`);
}

function record(input: unknown, path: string): Record<string, unknown> {
  if (typeof input !== "object" || input === null || Array.isArray(input)) fail(path, "must be an object");
  return input as Record<string, unknown>;
}

function text(input: unknown, path: string): string {
  if (typeof input !== "string" || input.trim().length === 0 || input.length > MAX_TEXT) {
    fail(path, `must be a nonempty string of at most ${MAX_TEXT} characters`);
  }
  return input;
}

function matching(input: unknown, pattern: RegExp, path: string): string {
  const value = text(input, path);
  if (!pattern.test(value)) fail(path, `has an invalid format: ${JSON.stringify(value).slice(0, 80)}`);
  return value;
}

function optional(value: Record<string, unknown>, key: string, path: string, check: (input: unknown, path: string) => void): void {
  if (value[key] !== undefined) check(value[key], `${path}.${key}`);
}

function bool(input: unknown, path: string): void {
  if (typeof input !== "boolean") fail(path, "must be a boolean");
}

function positiveInteger(input: unknown, path: string): void {
  if (!Number.isInteger(input) || (input as number) <= 0) fail(path, "must be a positive integer");
}

function oneOf(values: readonly string[]) {
  return (input: unknown, path: string) => {
    if (typeof input !== "string" || !values.includes(input)) fail(path, `must be one of ${values.join(", ")}`);
  };
}

function list(check: (input: unknown, path: string) => void) {
  return (input: unknown, path: string) => {
    if (!Array.isArray(input)) fail(path, "must be an array");
    input.forEach((entry, index) => check(entry, `${path}[${index}]`));
    if (new Set(input).size !== input.length) fail(path, "has duplicates");
  };
}

export function allowedDocsUrl(raw: string): boolean {
  try {
    const url = new URL(raw);
    return url.protocol === "https:" && !url.username && !url.password && !url.port
      && (DOCS_URL_HOSTS as readonly string[]).includes(url.hostname);
  } catch {
    return false;
  }
}

function checkHarnessModel(input: unknown, path: string): HarnessModel {
  const model = record(input, path);
  matching(model.id, ID, `${path}.id`);
  text(model.name, `${path}.name`);
  text(model.shortName, `${path}.shortName`);
  optional(model, "ref", path, (v, p) => matching(v, ID, p));
  optional(model, "family", path, text);
  optional(model, "provider", path, (v, p) => matching(v, SLUG, p));
  optional(model, "efforts", path, list(oneOf(EFFORTS)));
  optional(model, "defaultEffort", path, oneOf(EFFORTS));
  optional(model, "fast", path, bool);
  optional(model, "aliases", path, list((v, p) => matching(v, ID, p)));
  optional(model, "status", path, oneOf(STATUSES));
  if (model.defaultEffort !== undefined && !(model.efforts as string[] | undefined)?.includes(model.defaultEffort as string)) {
    fail(`${path}.defaultEffort`, "must be one of its efforts");
  }
  return model as unknown as HarnessModel;
}

function checkHarness(input: unknown, path: string): CatalogHarness {
  const harness = record(input, path);
  matching(harness.id, SLUG, `${path}.id`);
  text(harness.name, `${path}.name`);
  matching(harness.brand, SLUG, `${path}.brand`);
  list((v, p) => matching(v, SLUG, p))(harness.families, `${path}.families`);
  oneOf(["catalog", "probe"])(harness.modelSource, `${path}.modelSource`);
  optional(harness, "docsUrl", path, (v, p) => {
    if (!allowedDocsUrl(text(v, p))) fail(p, "must be https on an allowed host");
  });
  if (!Array.isArray(harness.models) || harness.models.length > MAX_MODELS) fail(`${path}.models`, `must be an array of at most ${MAX_MODELS}`);
  const models = harness.models.map((model, index) => checkHarnessModel(model, `${path}.models[${index}]`));
  if (new Set(models.map((model) => model.id)).size !== models.length) fail(`${path}.models`, "has duplicate ids");
  optional(harness, "defaultModel", path, (v, p) => {
    if (!models.some((model) => model.id === v)) fail(p, "must name one of its models");
  });
  return harness as unknown as CatalogHarness;
}

function checkCost(input: unknown, path: string): void {
  const cost = record(input, path);
  for (const [key, value] of Object.entries(cost)) {
    if (!["input", "output", "cacheRead", "cacheWrite"].includes(key)) fail(`${path}.${key}`, "is not a known field");
    if (typeof value !== "number" || !Number.isFinite(value) || value < 0) fail(`${path}.${key}`, "must be a nonnegative number");
  }
}

function checkModelInfo(input: unknown, path: string): ModelInfo {
  const info = record(input, path);
  text(info.name, `${path}.name`);
  optional(info, "family", path, text);
  optional(info, "releaseDate", path, text);
  optional(info, "knowledge", path, text);
  optional(info, "contextWindow", path, positiveInteger);
  optional(info, "maxOutput", path, positiveInteger);
  optional(info, "input", path, list(oneOf(MODALITIES)));
  optional(info, "reasoning", path, bool);
  optional(info, "toolCall", path, bool);
  optional(info, "openWeights", path, bool);
  optional(info, "cost", path, checkCost);
  optional(info, "status", path, oneOf(STATUSES));
  return info as unknown as ModelInfo;
}

function checkHarnesses(input: unknown): void {
  if (!Array.isArray(input) || input.length === 0 || input.length > MAX_HARNESSES) {
    fail("catalog.harnesses", `must have 1 to ${MAX_HARNESSES} entries`);
  }
  const harnesses = input.map((entry, index) => checkHarness(entry, `catalog.harnesses[${index}]`));
  if (new Set(harnesses.map((harness) => harness.id)).size !== harnesses.length) fail("catalog.harnesses", "has duplicate ids");
}

/** Validates a complete catalog and its serialized size. Throws CatalogSchemaError. */
export function validateCatalog(input: unknown): ModelCatalog {
  const catalog = record(input, "catalog");
  if (catalog.schemaVersion !== SCHEMA_VERSION) fail("catalog.schemaVersion", `must be ${SCHEMA_VERSION}`);
  if (typeof catalog.generatedAt !== "string" || Number.isNaN(Date.parse(catalog.generatedAt))) {
    fail("catalog.generatedAt", "must be an ISO-8601 timestamp");
  }
  oneOf(["live", "snapshot"])(catalog.source, "catalog.source");
  checkHarnesses(catalog.harnesses);
  const models = record(catalog.models, "catalog.models");
  for (const [ref, info] of Object.entries(models)) {
    matching(ref, ID, `catalog.models key ${JSON.stringify(ref).slice(0, 80)}`);
    checkModelInfo(info, `catalog.models["${ref}"]`);
  }
  const providers = record(catalog.providers, "catalog.providers");
  for (const [id, provider] of Object.entries(providers)) {
    matching(id, SLUG, "catalog.providers key");
    text(record(provider, `catalog.providers.${id}`).name, `catalog.providers.${id}.name`);
  }
  const bytes = Buffer.byteLength(JSON.stringify(catalog));
  if (bytes > MAX_CATALOG_BYTES) fail("catalog", `is ${bytes} bytes, above the ${MAX_CATALOG_BYTES} byte limit`);
  return catalog as unknown as ModelCatalog;
}
