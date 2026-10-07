// The curated overrides file (web/data/model-catalog/overrides.json): the
// harness list, and per harness which models.dev providers and models it
// offers, with corrections. It is checked in and reviewed, so it is
// validated strictly at module load; a bad edit fails tests and the build.

import {
  CatalogSchemaError,
  HARNESS_ICONS,
  MODEL_STATUSES,
  record,
  text,
  validateCost,
  validateDocsUrl,
  validateEfforts,
  validateHarnessId,
  validateModalities,
  validateModelId,
  validateVersionString,
  type CatalogCost,
  type CatalogModalities,
  type HarnessIcon,
  type ModelStatus,
} from "./schema";

export const OVERRIDES_VERSION = 1;

/** How a harness spells a model id: `claude-opus-5` or `anthropic/claude-opus-5`. */
export type ModelIdStyle = "bare" | "provider-prefixed";

export interface ModelOverride {
  name?: string;
  shortName?: string;
  family?: string;
  default?: boolean;
  recommended?: boolean;
  /** Leave the model out of the catalog. `false` shows a model the default filters hide. */
  hidden?: boolean;
  contextWindow?: number;
  maxOutput?: number;
  cost?: CatalogCost;
  modalities?: CatalogModalities;
  efforts?: string[];
  defaultEffort?: string;
  fast?: boolean;
  minVersion?: string;
  status?: ModelStatus;
}

export interface ProviderRule {
  /** models.dev provider id. */
  id: string;
  /** Override of the models.dev provider name. */
  name?: string;
  /** `*`: every model models.dev lists that passes the default filters. Else these ids, in this order. */
  models: "*" | string[];
}

export interface HarnessOverride {
  id: string;
  name: string;
  icon?: HarnessIcon;
  docsUrl?: string;
  minVersion?: string;
  modelIds: ModelIdStyle;
  providers: ProviderRule[];
  /** Keyed `<provider>/<model id>`. A key models.dev does not list adds a model; it needs a name. */
  models: Record<string, ModelOverride>;
}

export interface CatalogOverrides {
  version: typeof OVERRIDES_VERSION;
  /** When a person last edited the file. */
  updatedAt: string;
  harnesses: HarnessOverride[];
}

function fail(path: string, message: string): never {
  throw new CatalogSchemaError(`${path} ${message}`);
}

function onlyKeys(value: Record<string, unknown>, allowed: readonly string[], path: string): void {
  for (const key of Object.keys(value)) if (!allowed.includes(key)) fail(`${path}.${key}`, "is not a known field");
}

function positiveInteger(input: unknown, path: string): number {
  if (!Number.isInteger(input) || (input as number) <= 0) fail(path, "must be a positive integer");
  return input as number;
}

function bool(input: unknown, path: string): boolean {
  if (typeof input !== "boolean") fail(path, "must be a boolean");
  return input;
}

type Check = (input: unknown, path: string) => unknown;
const MODEL_OVERRIDE_FIELDS: Record<keyof ModelOverride, Check> = {
  name: text,
  shortName: text,
  family: text,
  default: bool,
  recommended: bool,
  hidden: bool,
  contextWindow: positiveInteger,
  maxOutput: positiveInteger,
  cost: validateCost,
  modalities: validateModalities,
  efforts: validateEfforts,
  defaultEffort: text,
  fast: bool,
  minVersion: validateVersionString,
  status: (input, path) => {
    if (!MODEL_STATUSES.includes(input as ModelStatus)) fail(path, `must be one of ${MODEL_STATUSES.join(", ")}`);
    return input;
  },
};

function validateModelOverride(input: unknown, path: string): ModelOverride {
  const value = record(input, path);
  onlyKeys(value, Object.keys(MODEL_OVERRIDE_FIELDS), path);
  const out: Record<string, unknown> = {};
  for (const [key, check] of Object.entries(MODEL_OVERRIDE_FIELDS)) {
    if (value[key] !== undefined) out[key] = check(value[key], `${path}.${key}`);
  }
  return out as ModelOverride;
}

function validateProviderRule(input: unknown, path: string): ProviderRule {
  const value = record(input, path);
  onlyKeys(value, ["id", "name", "models"], path);
  const rule: ProviderRule = { id: validateHarnessId(value.id, `${path}.id`), models: "*" };
  if (value.name !== undefined) rule.name = text(value.name, `${path}.name`);
  if (value.models === "*") return rule;
  if (!Array.isArray(value.models) || value.models.length === 0) fail(`${path}.models`, 'must be "*" or a nonempty array');
  rule.models = value.models.map((id, index) => validateModelId(id, `${path}.models[${index}]`));
  if (new Set(rule.models).size !== rule.models.length) fail(`${path}.models`, "has duplicates");
  return rule;
}

function validateModelOverrides(input: unknown, path: string, providers: ProviderRule[]): Record<string, ModelOverride> {
  if (input === undefined) return {};
  const value = record(input, path);
  const out: Record<string, ModelOverride> = {};
  for (const [key, entry] of Object.entries(value)) {
    const slash = key.indexOf("/");
    const provider = slash > 0 ? key.slice(0, slash) : "";
    if (!providers.some((rule) => rule.id === provider)) fail(`${path}["${key}"]`, "must start with one of its provider ids and a slash");
    validateModelId(key.slice(slash + 1), `${path}["${key}"]`);
    out[key] = validateModelOverride(entry, `${path}["${key}"]`);
  }
  return out;
}

function validateHarnessOverride(input: unknown, path: string): HarnessOverride {
  const value = record(input, path);
  onlyKeys(value, ["id", "name", "icon", "docsUrl", "minVersion", "modelIds", "providers", "models"], path);
  if (value.modelIds !== "bare" && value.modelIds !== "provider-prefixed") fail(`${path}.modelIds`, 'must be "bare" or "provider-prefixed"');
  if (!Array.isArray(value.providers)) fail(`${path}.providers`, "must be an array");
  const providers = value.providers.map((rule, index) => validateProviderRule(rule, `${path}.providers[${index}]`));
  if (new Set(providers.map((rule) => rule.id)).size !== providers.length) fail(`${path}.providers`, "has duplicate ids");
  if (value.modelIds === "bare" && providers.length > 1) fail(`${path}.modelIds`, "must be provider-prefixed when a harness has more than one provider");
  const harness: HarnessOverride = {
    id: validateHarnessId(value.id, `${path}.id`),
    name: text(value.name, `${path}.name`),
    modelIds: value.modelIds,
    providers,
    models: validateModelOverrides(value.models, `${path}.models`, providers),
  };
  if (value.icon !== undefined) {
    if (!HARNESS_ICONS.includes(value.icon as HarnessIcon)) fail(`${path}.icon`, `must be one of ${HARNESS_ICONS.join(", ")}`);
    harness.icon = value.icon as HarnessIcon;
  }
  if (value.docsUrl !== undefined) harness.docsUrl = validateDocsUrl(value.docsUrl, `${path}.docsUrl`);
  if (value.minVersion !== undefined) harness.minVersion = validateVersionString(value.minVersion, `${path}.minVersion`);
  return harness;
}

export function validateOverrides(input: unknown): CatalogOverrides {
  const value = record(input, "overrides");
  onlyKeys(value, ["$comment", "version", "updatedAt", "harnesses"], "overrides");
  if (value.version !== OVERRIDES_VERSION) fail("overrides.version", `must be ${OVERRIDES_VERSION}`);
  const updatedAt = text(value.updatedAt, "overrides.updatedAt");
  if (Number.isNaN(Date.parse(updatedAt))) fail("overrides.updatedAt", "must be an ISO-8601 timestamp");
  if (!Array.isArray(value.harnesses) || value.harnesses.length === 0) fail("overrides.harnesses", "must be a nonempty array");
  const harnesses = value.harnesses.map((entry, index) => validateHarnessOverride(entry, `overrides.harnesses[${index}]`));
  if (new Set(harnesses.map((harness) => harness.id)).size !== harnesses.length) fail("overrides.harnesses", "has duplicate ids");
  return { version: OVERRIDES_VERSION, updatedAt, harnesses };
}

/** Every models.dev provider any harness reads, sorted. */
export function curatedProviderIds(overrides: CatalogOverrides): string[] {
  return [...new Set(overrides.harnesses.flatMap((harness) => harness.providers.map((rule) => rule.id)))].sort();
}
