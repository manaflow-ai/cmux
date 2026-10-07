import { HARNESS_OVERRIDES, METADATA_PROVIDERS, type HarnessOverride, type HarnessSource } from "./overrides";
import type {
  CatalogHarness,
  EffortValue,
  HarnessModel,
  InputModality,
  ModelCatalog,
  ModelInfo,
  ModelStatus,
} from "./types";

// Projects the public model feed (about 5 MB: providers -> models) through the cmux overrides into
// the catalog the app reads (about 150 KB). The feed is third-party data, so every field is checked
// and a malformed model is skipped; only a feed that yields no Claude Code or Codex model fails.

type FeedModel = Record<string, unknown> & { id: string; name: string };
type FeedProvider = { id: string; name: string; models: FeedModel[] };

const EFFORTS: readonly EffortValue[] = ["none", "minimal", "low", "medium", "high", "xhigh", "max"];
const MODALITIES: readonly InputModality[] = ["text", "image", "pdf", "audio", "video"];
const REQUIRED_HARNESSES = ["claude", "codex"];

export function projectCatalog(
  feed: unknown,
  now: Date,
  overrides: HarnessOverride[] = HARNESS_OVERRIDES,
  source: ModelCatalog["source"] = "live",
): ModelCatalog {
  const providers = readFeed(feed);
  const harnesses = overrides.map((override) => projectHarness(override, providers));
  for (const id of REQUIRED_HARNESSES) {
    if (!harnesses.some((entry) => entry.id === id && entry.models.length > 0)) {
      throw new Error(`model feed yields no models for harness ${id}`);
    }
  }
  const models: Record<string, ModelInfo> = {};
  const names: Record<string, { name: string }> = {};
  for (const providerId of METADATA_PROVIDERS) {
    const provider = providers.get(providerId);
    if (!provider) continue;
    names[providerId] = { name: provider.name };
    for (const model of provider.models) models[`${providerId}/${model.id}`] = modelInfo(model);
  }
  return { schemaVersion: 1, generatedAt: now.toISOString(), source, harnesses, models, providers: names };
}

function readFeed(feed: unknown): Map<string, FeedProvider> {
  if (!isRecord(feed)) throw new Error("model feed must be an object");
  const providers = new Map<string, FeedProvider>();
  for (const [id, raw] of Object.entries(feed)) {
    if (!isRecord(raw) || !isRecord(raw.models)) continue;
    const models = Object.values(raw.models).filter(isFeedModel);
    providers.set(id, { id, name: text(raw.name) ?? id, models });
  }
  return providers;
}

function projectHarness(override: HarnessOverride, providers: Map<string, FeedProvider>): CatalogHarness {
  const listed: { model: FeedModel; provider: FeedProvider }[] = [];
  for (const source of override.sources ?? []) {
    const provider = providers.get(source.provider);
    if (!provider) continue;
    for (const model of provider.models) if (selected(model, source)) listed.push({ model, provider });
  }
  const models = listed
    .map(({ model, provider }) => harnessModel(override, model, provider, providers))
    .filter((model) => !override.models?.[model.id]?.hidden)
    .sort(byGroupThenNewest(override, listed));
  addFamilyAliases(override, models, listed);
  const defaultModel = models.some((model) => model.id === override.defaultModel)
    ? override.defaultModel
    : models[0]?.id;
  return {
    id: override.id,
    name: override.name,
    brand: override.brand,
    families: override.families,
    modelSource: override.modelSource,
    ...(override.docsUrl ? { docsUrl: override.docsUrl } : {}),
    ...(defaultModel ? { defaultModel } : {}),
    models,
  };
}

function harnessModel(
  override: HarnessOverride,
  model: FeedModel,
  provider: FeedProvider,
  providers: Map<string, FeedProvider>,
): HarnessModel {
  const name = cleanName(model.name);
  const efforts = effortsOf(model).filter((effort) => !override.dropEfforts?.includes(effort));
  // Gateway ids are "<maker>/<model>": the maker is the provider the user recognizes.
  const maker = override.groupByProvider ? model.id.split("/")[0] : provider.id;
  const family = override.groupByProvider
    ? providers.get(maker ?? "")?.name ?? maker
    : familyName(override, text(model.family));
  const result: HarnessModel = {
    id: model.id,
    ref: `${provider.id}/${model.id}`,
    name,
    shortName: shortName(name, override.shortNamePrefix),
    ...(family ? { family } : {}),
    ...(maker ? { provider: maker } : {}),
    ...(efforts.length > 0 ? { efforts } : {}),
    ...(override.defaultEffort && efforts.includes(override.defaultEffort)
      ? { defaultEffort: override.defaultEffort }
      : {}),
    ...(hasFastMode(model) ? { fast: true } : {}),
    ...(statusOf(model) ? { status: statusOf(model) } : {}),
  };
  const extra = Object.fromEntries(
    Object.entries(override.models?.[model.id] ?? {}).filter(([key]) => key !== "hidden"),
  ) as Partial<HarnessModel>;
  return { ...result, ...extra };
}

/** Groups follow the override's family order, then the newest member (the feed's key order is
 *  unstable); members sort newest first. */
function byGroupThenNewest(
  override: HarnessOverride,
  listed: { model: FeedModel }[],
): (a: HarnessModel, b: HarnessModel) => number {
  const released = new Map(listed.map(({ model }) => [model.id, text(model.release_date) ?? ""]));
  const groupNewest = new Map<string, string>();
  for (const { model } of listed) {
    const group = groupKey(override, model.id, text(model.family));
    const date = released.get(model.id) ?? "";
    if (date > (groupNewest.get(group) ?? "")) groupNewest.set(group, date);
  }
  const familyOf = new Map(listed.map(({ model }) => [model.id, groupKey(override, model.id, text(model.family))]));
  const ranked = Object.keys(override.familyNames ?? {});
  const rank = (group: string) => (ranked.includes(group) ? ranked.indexOf(group) : ranked.length);
  return (a, b) => {
    const groupA = familyOf.get(a.id) ?? "";
    const groupB = familyOf.get(b.id) ?? "";
    if (groupA !== groupB) {
      const ranks = rank(groupA) - rank(groupB);
      if (ranks !== 0) return ranks;
      const newer = (groupNewest.get(groupB) ?? "").localeCompare(groupNewest.get(groupA) ?? "");
      return newer !== 0 ? newer : groupA.localeCompare(groupB);
    }
    const dateOrder = (released.get(b.id) ?? "").localeCompare(released.get(a.id) ?? "");
    return dateOrder !== 0 ? dateOrder : a.id.localeCompare(b.id);
  };
}

function groupKey(override: HarnessOverride, id: string, family: string | undefined): string {
  return override.groupByProvider ? (id.split("/")[0] ?? id) : (family ?? id);
}

/** The newest model of each aliased family takes the harness's short alias ("opus"). */
function addFamilyAliases(override: HarnessOverride, models: HarnessModel[], listed: { model: FeedModel }[]): void {
  if (!override.familyAliases) return;
  const families = new Map(listed.map(({ model }) => [model.id, text(model.family)]));
  for (const [family, alias] of Object.entries(override.familyAliases)) {
    const newest = models.find((model) => families.get(model.id) === family);
    if (newest && !models.some((model) => model.aliases?.includes(alias))) {
      newest.aliases = [...(newest.aliases ?? []), alias];
    }
  }
}

function selected(model: FeedModel, source: HarnessSource): boolean {
  const included = !source.include || source.include.some((pattern) => matches(model.id, pattern));
  if (model.tool_call === false) return false;
  const recent = !source.minReleaseDate || (text(model.release_date) ?? "") >= source.minReleaseDate;
  return included && recent && !(source.exclude ?? []).some((pattern) => matches(model.id, pattern));
}

/** "*suffix" matches the end (with [0-9] digit classes); anything else is an id prefix. */
function matches(id: string, pattern: string): boolean {
  if (!pattern.startsWith("*")) return id.startsWith(pattern);
  const suffix = pattern.slice(1).replace(/[.+?^${}()|\\]/g, "\\$&");
  return new RegExp(`${suffix}$`).test(id);
}

function modelInfo(model: FeedModel): ModelInfo {
  const limit = isRecord(model.limit) ? model.limit : {};
  const modalities = isRecord(model.modalities) ? model.modalities : {};
  const input = Array.isArray(modalities.input)
    ? modalities.input.filter((value): value is InputModality => MODALITIES.includes(value as InputModality))
    : [];
  const info: ModelInfo = { name: cleanName(model.name) };
  assign(info, "family", text(model.family));
  assign(info, "releaseDate", text(model.release_date));
  assign(info, "knowledge", text(model.knowledge));
  assign(info, "contextWindow", positiveInteger(limit.context));
  assign(info, "maxOutput", positiveInteger(limit.output));
  if (input.length > 0) info.input = input;
  assign(info, "reasoning", bool(model.reasoning));
  assign(info, "toolCall", bool(model.tool_call));
  assign(info, "openWeights", bool(model.open_weights));
  assign(info, "cost", costOf(model.cost));
  assign(info, "status", statusOf(model));
  return info;
}

function costOf(raw: unknown): ModelInfo["cost"] {
  if (!isRecord(raw)) return undefined;
  const cost: NonNullable<ModelInfo["cost"]> = {};
  assign(cost, "input", price(raw.input));
  assign(cost, "output", price(raw.output));
  assign(cost, "cacheRead", price(raw.cache_read));
  assign(cost, "cacheWrite", price(raw.cache_write));
  return Object.keys(cost).length > 0 ? cost : undefined;
}

function effortsOf(model: FeedModel): EffortValue[] {
  if (!Array.isArray(model.reasoning_options)) return [];
  const option = model.reasoning_options.find((entry) => isRecord(entry) && entry.type === "effort");
  if (!isRecord(option) || !Array.isArray(option.values)) return [];
  return EFFORTS.filter((effort) => (option.values as unknown[]).includes(effort));
}

function hasFastMode(model: FeedModel): boolean {
  const experimental = isRecord(model.experimental) ? model.experimental : {};
  return isRecord(experimental.modes) && isRecord(experimental.modes.fast);
}

function statusOf(model: FeedModel): ModelStatus | undefined {
  if (model.status === "deprecated") return "deprecated";
  if (model.status === "beta" || model.status === "alpha" || model.status === "preview") return "preview";
  return undefined;
}

function familyName(override: HarnessOverride, family: string | undefined): string | undefined {
  if (!family) return undefined;
  return override.familyNames?.[family] ?? family;
}

/** The feed marks moving aliases "(latest)"; the composer shows the model's own name. */
function cleanName(name: string): string {
  return name.replace(/\s*\(latest\)\s*$/i, "").trim();
}

function shortName(name: string, prefix: string | undefined): string {
  return prefix && name.startsWith(prefix) && name.length > prefix.length ? name.slice(prefix.length) : name;
}

function assign<T extends object, K extends keyof T>(target: T, key: K, value: T[K] | undefined): void {
  if (value !== undefined) target[key] = value;
}

function isFeedModel(value: unknown): value is FeedModel {
  return isRecord(value) && text(value.id) !== undefined && text(value.name) !== undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function text(value: unknown): string | undefined {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : undefined;
}

function bool(value: unknown): boolean | undefined {
  return typeof value === "boolean" ? value : undefined;
}

function positiveInteger(value: unknown): number | undefined {
  return typeof value === "number" && Number.isInteger(value) && value > 0 ? value : undefined;
}

function price(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined;
}
