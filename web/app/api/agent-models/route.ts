import { createHash } from "node:crypto";

import {
  agentModelCatalog,
  type AgentModel,
  type AgentModelCatalog,
  type AgentModelChoice,
  type AgentModelProvider,
  type AgentModelServiceTier,
} from "../../../data/agent-models";


const CACHE_CONTROL = "public, s-maxage=300, stale-while-revalidate=86400";
const ALLOW_METHODS = "GET, OPTIONS";
const ALLOW_HEADERS = "If-None-Match, Content-Type";
const REQUIRED_PROVIDERS = ["claude", "codex", "gemini", "opencode"] as const;
const PAYLOAD = JSON.stringify(validateAndDeduplicateCatalog(agentModelCatalog));
const ETAG = `"${createHash("sha256").update(PAYLOAD).digest("base64url")}"`;

/**
 * Validates the versioned backend payload before it can be served and removes
 * duplicate model identifiers within each provider. The first occurrence wins
 * so a catalog edit cannot silently replace earlier metadata by appending a
 * second entry with the same CLI identifier.
 */
export function validateAndDeduplicateCatalog(input: unknown): AgentModelCatalog {
  const catalog = record(input, "catalog");
  if (catalog.schemaVersion !== 1) {
    throw new Error("agent model catalog schemaVersion must be 1");
  }

  const updatedAt = nonemptyString(catalog.updatedAt, "catalog.updatedAt");
  if (Number.isNaN(Date.parse(updatedAt))) {
    throw new Error("agent model catalog updatedAt must be an ISO-8601 timestamp");
  }

  const rawProviders = record(catalog.providers, "catalog.providers");
  const providers: Record<string, AgentModelProvider> = {};
  for (const [providerName, rawProvider] of Object.entries(rawProviders)) {
    if (providerName.trim().length === 0) {
      throw new Error("agent model catalog provider names must not be empty");
    }
    providers[providerName] = validateProvider(rawProvider, providerName);
  }
  for (const providerName of REQUIRED_PROVIDERS) {
    if (!providers[providerName]) {
      throw new Error(`agent model catalog is missing provider ${providerName}`);
    }
  }

  return {
    schemaVersion: 1,
    updatedAt,
    providers: providers as unknown as AgentModelCatalog["providers"],
  };
}

function validateProvider(input: unknown, providerName: string): AgentModelProvider {
  const provider = record(input, `providers.${providerName}`);
  const defaultModel = nonemptyString(
    provider.defaultModel,
    `providers.${providerName}.defaultModel`,
  );
  if (!Array.isArray(provider.models) || provider.models.length === 0) {
    throw new Error(`providers.${providerName}.models must be a nonempty array`);
  }

  const seenIDs = new Set<string>();
  const models: AgentModel[] = [];
  for (const [index, inputModel] of provider.models.entries()) {
    const path = `providers.${providerName}.models[${index}]`;
    const model = record(inputModel, path);
    const id = nonemptyString(model.id, `${path}.id`);
    const label = nonemptyString(model.label, `${path}.label`);
    validateModelMetadata(model, path);
    if (seenIDs.has(id)) continue;
    seenIDs.add(id);
    models.push({ ...model, id, label } as unknown as AgentModel);
  }

  if (!seenIDs.has(defaultModel)) {
    throw new Error(
      `providers.${providerName}.defaultModel must identify one of its models`,
    );
  }
  return { defaultModel, models };
}

function validateModelMetadata(model: Record<string, unknown>, path: string): void {
  optionalString(model.description, `${path}.description`);
  optionalString(model.minVersion, `${path}.minVersion`);
  optionalBoolean(model.supportsOneMillion, `${path}.supportsOneMillion`);
  optionalBoolean(model.fast, `${path}.fast`);
  optionalBoolean(model.deprecated, `${path}.deprecated`);
  optionalBoolean(model.isDefault, `${path}.isDefault`);
  if (model.contextWindow !== undefined
      && (!Number.isInteger(model.contextWindow) || (model.contextWindow as number) <= 0)) {
    throw new Error(`${path}.contextWindow must be a positive integer`);
  }

  validateChoices(model.efforts, `${path}.efforts`);
  optionalString(model.defaultEffort, `${path}.defaultEffort`);
  if (model.defaultEffort !== undefined && Array.isArray(model.efforts)) {
    const effortValues = new Set(
      model.efforts.map((effort, index) => choice(effort, `${path}.efforts[${index}]`).value),
    );
    if (!effortValues.has(model.defaultEffort as string)) {
      throw new Error(`${path}.defaultEffort must identify one of its efforts`);
    }
  }

  validateServiceTiers(model.serviceTiers, `${path}.serviceTiers`);
  if (model.defaultServiceTier !== undefined && model.defaultServiceTier !== null) {
    const defaultServiceTier = nonemptyString(
      model.defaultServiceTier,
      `${path}.defaultServiceTier`,
    );
    if (Array.isArray(model.serviceTiers)) {
      const tierIDs = new Set(
        model.serviceTiers.map((tier, index) => (
          serviceTier(tier, `${path}.serviceTiers[${index}]`).id
        )),
      );
      if (!tierIDs.has(defaultServiceTier)) {
        throw new Error(`${path}.defaultServiceTier must identify one of its serviceTiers`);
      }
    }
  }
}

function validateChoices(input: unknown, path: string): void {
  if (input === undefined) return;
  if (!Array.isArray(input) || input.length === 0) {
    throw new Error(`${path} must be a nonempty array`);
  }
  const values = new Set<string>();
  for (const [index, inputChoice] of input.entries()) {
    const value = choice(inputChoice, `${path}[${index}]`).value;
    if (values.has(value)) throw new Error(`${path} contains duplicate value ${value}`);
    values.add(value);
  }
}

function choice(input: unknown, path: string): AgentModelChoice {
  const value = record(input, path);
  const choiceValue = nonemptyString(value.value, `${path}.value`);
  const label = nonemptyString(value.label, `${path}.label`);
  optionalString(value.description, `${path}.description`);
  return { ...value, value: choiceValue, label } as unknown as AgentModelChoice;
}

function validateServiceTiers(input: unknown, path: string): void {
  if (input === undefined) return;
  if (!Array.isArray(input) || input.length === 0) {
    throw new Error(`${path} must be a nonempty array`);
  }
  const ids = new Set<string>();
  for (const [index, inputTier] of input.entries()) {
    const id = serviceTier(inputTier, `${path}[${index}]`).id;
    if (ids.has(id)) throw new Error(`${path} contains duplicate id ${id}`);
    ids.add(id);
  }
}

function serviceTier(input: unknown, path: string): AgentModelServiceTier {
  const value = record(input, path);
  const id = nonemptyString(value.id, `${path}.id`);
  const name = nonemptyString(value.name, `${path}.name`);
  optionalString(value.description, `${path}.description`);
  return { ...value, id, name } as unknown as AgentModelServiceTier;
}

function record(input: unknown, path: string): Record<string, unknown> {
  if (typeof input !== "object" || input === null || Array.isArray(input)) {
    throw new Error(`${path} must be an object`);
  }
  return input as Record<string, unknown>;
}

function nonemptyString(input: unknown, path: string): string {
  if (typeof input !== "string" || input.trim().length === 0) {
    throw new Error(`${path} must be a nonempty string`);
  }
  return input.trim();
}

function optionalString(input: unknown, path: string): void {
  if (input !== undefined) nonemptyString(input, path);
}

function optionalBoolean(input: unknown, path: string): void {
  if (input !== undefined && typeof input !== "boolean") {
    throw new Error(`${path} must be a boolean`);
  }
}

export async function GET(request: Request): Promise<Response> {
  if (matchesETag(request.headers.get("if-none-match"))) {
    return new Response(null, {
      status: 304,
      headers: commonHeaders(),
    });
  }

  return new Response(PAYLOAD, {
    status: 200,
    headers: {
      ...commonHeaders(),
      "Content-Type": "application/json; charset=utf-8",
    },
  });
}

export function OPTIONS(): Response {
  return new Response(null, {
    status: 204,
    headers: commonHeaders(),
  });
}

function commonHeaders(): Record<string, string> {
  return {
    "Cache-Control": CACHE_CONTROL,
    ETag: ETAG,
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": ALLOW_METHODS,
    "Access-Control-Allow-Headers": ALLOW_HEADERS,
  };
}

function matchesETag(header: string | null): boolean {
  if (!header) return false;
  return header.split(",").some((value) => {
    const candidate = value.trim();
    return candidate === ETAG || candidate === "*";
  });
}
