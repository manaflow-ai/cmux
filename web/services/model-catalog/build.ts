// models.dev data + the curated overrides -> the served catalog.
// Pure: the same inputs always give the same bytes, so the ETag is a content hash.

import type { CatalogOverrides, HarnessOverride, ModelOverride, ProviderRule } from "./overrides";
import { CatalogSchemaError, validateCatalog, type CatalogHarness, type CatalogModel, type ModelCatalog } from "./schema";
import type { UpstreamModel, UpstreamProvider, UpstreamSubset } from "./upstream";

/** Hidden unless an override sets `hidden: false`: deprecated, no text output, or no tool calls. */
function hiddenByDefault(model: UpstreamModel): boolean {
  if (model.status === "deprecated") return true;
  if (model.modalities && !model.modalities.output.includes("text")) return true;
  return model.toolCall === false;
}

function newestFirst(a: UpstreamModel, b: UpstreamModel): number {
  const byDate = (b.releaseDate ?? "").localeCompare(a.releaseDate ?? "");
  return byDate !== 0 ? byDate : a.id.localeCompare(b.id);
}

type Candidate = { id: string; upstream?: UpstreamModel; override?: ModelOverride };

/** The models one provider rule offers, in catalog order. */
function candidates(rule: ProviderRule, provider: UpstreamProvider | undefined, overrides: Record<string, ModelOverride>): Candidate[] {
  const overrideFor = (id: string) => overrides[`${rule.id}/${id}`];
  const upstream = provider?.models ?? {};
  if (rule.models !== "*") {
    return rule.models.map((id) => ({ id, upstream: upstream[id], override: overrideFor(id) }));
  }
  const listed = Object.values(upstream)
    .filter((model) => overrideFor(model.id)?.hidden === false || !hiddenByDefault(model))
    .sort(newestFirst)
    .map((model) => ({ id: model.id, upstream: model, override: overrideFor(model.id) }));
  const prefix = `${rule.id}/`;
  const manual = Object.keys(overrides)
    .filter((key) => key.startsWith(prefix) && !upstream[key.slice(prefix.length)])
    .map((key) => ({ id: key.slice(prefix.length), override: overrides[key] }));
  return [...listed, ...manual];
}

function definedOnly<T extends object>(value: T): T {
  return Object.fromEntries(Object.entries(value).filter(([, entry]) => entry !== undefined)) as T;
}

function flag(value: boolean | undefined): true | undefined {
  return value === true ? true : undefined;
}

function upstreamFields(upstream: UpstreamModel | undefined): Partial<CatalogModel> {
  if (!upstream) return {};
  const { family, contextWindow, maxOutput, cost, modalities, reasoning, toolCall, attachment, openWeights, releaseDate, knowledge, status } = upstream;
  return definedOnly({ family, contextWindow, maxOutput, cost, modalities, reasoning, toolCall, attachment, openWeights, releaseDate, knowledge, status });
}

function overrideFields(override: ModelOverride): Partial<CatalogModel> {
  const { shortName, family, contextWindow, maxOutput, cost, modalities, efforts, fast, minVersion, status } = override;
  return definedOnly({
    shortName,
    family,
    default: flag(override.default),
    recommended: flag(override.recommended),
    contextWindow,
    maxOutput,
    cost,
    modalities,
    efforts,
    defaultEffort: efforts ? override.defaultEffort : undefined,
    fast,
    minVersion,
    status,
  });
}

/** One served model, or undefined when it is hidden or has nothing to show. */
function catalogModel(candidate: Candidate, rule: ProviderRule, provider: UpstreamProvider | undefined, harness: HarnessOverride): CatalogModel | undefined {
  const { upstream, override = {} } = candidate;
  if (override.hidden === true) return undefined;
  const name = override.name ?? upstream?.name;
  // A curated id that models.dev does not list and the overrides do not name: leave it out.
  if (!name) return undefined;
  return {
    id: harness.modelIds === "bare" ? candidate.id : `${rule.id}/${candidate.id}`,
    name,
    provider: rule.id,
    providerName: rule.name ?? provider?.name ?? rule.id,
    ...upstreamFields(upstream),
    ...overrideFields(override),
  };
}

function buildHarness(harness: HarnessOverride, subset: UpstreamSubset): CatalogHarness {
  const models: CatalogModel[] = [];
  const seen = new Set<string>();
  for (const rule of harness.providers) {
    const provider = subset.providers[rule.id];
    for (const candidate of candidates(rule, provider, harness.models)) {
      const model = catalogModel(candidate, rule, provider, harness);
      if (!model || seen.has(model.id)) continue;
      seen.add(model.id);
      models.push(model);
    }
  }
  const defaults = models.filter((model) => model.default);
  if (defaults.length > 1) throw new CatalogSchemaError(`harness ${harness.id} has more than one default model`);
  return definedOnly({
    id: harness.id,
    name: harness.name,
    icon: harness.icon,
    docsUrl: harness.docsUrl,
    minVersion: harness.minVersion,
    defaultModel: defaults[0]?.id,
    models,
  });
}

function dayStart(date: string): number {
  return Date.parse(date.length === 7 ? `${date}-01T00:00:00.000Z` : `${date}T00:00:00.000Z`);
}

/** The newest change in the content, so it moves only when the data does. */
function contentDate(overrides: CatalogOverrides, harnesses: CatalogHarness[], subset: UpstreamSubset): string {
  let newest = Date.parse(overrides.updatedAt);
  for (const harness of harnesses) {
    for (const model of harness.models) {
      const upstream = subset.providers[model.provider]?.models[model.id.slice(model.id.indexOf("/") + 1)]
        ?? subset.providers[model.provider]?.models[model.id];
      const date = upstream?.lastUpdated ?? upstream?.releaseDate;
      if (date) newest = Math.max(newest, dayStart(date));
    }
  }
  return new Date(newest).toISOString();
}

/** Builds and strictly validates the catalog. Throws CatalogSchemaError. */
export function buildCatalog(subset: UpstreamSubset, overrides: CatalogOverrides): ModelCatalog {
  const harnesses = overrides.harnesses.map((harness) => buildHarness(harness, subset));
  return validateCatalog({ version: 1, updatedAt: contentDate(overrides, harnesses, subset), harnesses });
}
