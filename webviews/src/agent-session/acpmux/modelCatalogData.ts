import bundledCatalog from "../../../../web/data/model-catalog/snapshot.json";
import { agentName } from "./agents";
import type { AcpmuxSnapshot } from "./model";
import { agentKey } from "../shared/agentKey";
import { agentBrand } from "../shared/agentBrands.generated";

// The composer's model catalog as data (decision M2; contract .cmux-scratch/nx-model-catalog/
// CONTRACT.md). Three layers meet here: the cmux catalog (the server's projection of the public
// model feed plus cmux overrides, delivered by the app host, else the snapshot bundled with the
// page), the user's cmux.json `agentPane.models`, and what acpmux reports it can run. The picker
// reads only `PickerCatalog`; it never matches model ids itself.

export type EffortValue = "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max";
export type ModelStatus = "preview" | "deprecated";

export type ModelInfo = {
  name: string;
  family?: string;
  releaseDate?: string;
  knowledge?: string;
  contextWindow?: number;
  maxOutput?: number;
  input?: string[];
  reasoning?: boolean;
  toolCall?: boolean;
  openWeights?: boolean;
  cost?: { input?: number; output?: number; cacheRead?: number; cacheWrite?: number };
  status?: ModelStatus;
};

export type HarnessModel = {
  id: string;
  ref?: string;
  name: string;
  shortName: string;
  family?: string;
  provider?: string;
  efforts?: EffortValue[];
  defaultEffort?: EffortValue;
  fast?: boolean;
  aliases?: string[];
  status?: ModelStatus;
  /** Context window for a user-added model with no feed ref. */
  contextWindow?: number;
};

export type CatalogHarness = {
  id: string;
  name: string;
  brand: string;
  families: string[];
  modelSource: "catalog" | "probe";
  pickable?: boolean;
  kind?: string;
  defaultModel?: string;
  models: HarnessModel[];
};

export type ModelCatalog = {
  schemaVersion: 1;
  generatedAt: string;
  source: "live" | "snapshot";
  delivery?: "network" | "disk" | "bundled";
  harnesses: CatalogHarness[];
  models: Record<string, ModelInfo>;
  providers: Record<string, { name: string }>;
  diagnostics?: { path: string; message: string }[];
};

/** cmux.json `agentPane.models`, as the host passes it (unchecked JSON). */
export type ModelUserLayer = {
  remoteCatalog?: boolean;
  harnesses?: Record<string, { hidden?: boolean; name?: string; order?: number; defaultModel?: string }>;
  overrides?: Record<string, Partial<HarnessModel> & { hidden?: boolean }>;
};

export type PickerModel = {
  id: string;
  name: string;
  shortName: string;
  family?: string;
  providerName?: string;
  efforts: EffortValue[];
  defaultEffort?: EffortValue;
  fast: boolean;
  contextWindow?: number;
  reasoning?: boolean;
  input?: string[];
  status?: ModelStatus;
  unavailable?: string;
  searchText: string;
};

export type PickerHarness = {
  id: string;
  name: string;
  /** AgentMark brand id; null = no brand (use `iconUrl`, else the generic glyph). */
  brand: string | null;
  /** A host-served icon an acpmux profile declared (`_acpmux/harnesses` `icon` that is not a brand). */
  iconUrl?: string;
  acpmuxHarness: string | null;
  /** acpmux has a harness of this family. A catalog harness that is not installed still lists. */
  installed: boolean;
  pickable: boolean;
  unavailable?: string;
  defaultModel?: string;
  models: PickerModel[];
};

export type PickerCatalog = { harnesses: PickerHarness[]; provisional: boolean };

type AcpmuxCatalog = AcpmuxSnapshot["catalog"];
type AcpmuxHarness = AcpmuxCatalog[number];
type AcpmuxModel = AcpmuxHarness["models"][number];
type ConfigOptions = NonNullable<NonNullable<AcpmuxSnapshot["summary"]>["configOptions"]>;

/** The catalog bundled with the page: what the picker shows before the host answers, and offline. */
export const BUNDLED_MODEL_CATALOG: ModelCatalog = {
  ...(bundledCatalog as ModelCatalog),
  delivery: "bundled",
};

const EFFORT_ORDER: readonly EffortValue[] = ["none", "minimal", "low", "medium", "high", "xhigh", "max"];

/** A host payload when it is a schema 1 catalog, else undefined (the page keeps what it has). */
export function readModelCatalog(value: unknown): ModelCatalog | undefined {
  if (!isRecord(value) || value.schemaVersion !== 1 || !Array.isArray(value.harnesses)) return undefined;
  if (!isRecord(value.models) || !isRecord(value.providers)) return undefined;
  const harnesses = (value.harnesses as unknown[]).filter(isCatalogHarness);
  return { ...(value as ModelCatalog), harnesses };
}

/** Applies cmux.json `agentPane.models` to a catalog. Bad entries are skipped and reported. */
export function applyUserLayer(catalog: ModelCatalog, user: unknown): ModelCatalog {
  if (!isRecord(user)) return catalog;
  const diagnostics: { path: string; message: string }[] = [...(catalog.diagnostics ?? [])];
  const harnessConfig = isRecord(user.harnesses) ? user.harnesses : {};
  const overrides = isRecord(user.overrides) ? user.overrides : {};
  const harnesses = catalog.harnesses
    .filter((harness) => {
      const config = harnessConfig[harness.id];
      return !(isRecord(config) && config.hidden === true);
    })
    .map((harness, index) => ({
      harness: withHarnessConfig(harness, harnessConfig[harness.id]),
      order: orderOf(harnessConfig[harness.id], index),
    }))
    .sort((a, b) => a.order - b.order)
    .map(({ harness }) => harness);
  for (const [key, raw] of Object.entries(overrides)) {
    const slash = key.indexOf("/");
    if (slash <= 0 || slash === key.length - 1 || !isRecord(raw)) {
      diagnostics.push({
        path: `agentPane.models.overrides.${key}`,
        message: 'expected "<harness>/<model>": {…}',
      });
      continue;
    }
    const harnessId = key.slice(0, slash);
    const modelId = key.slice(slash + 1);
    for (const harness of harnesses) {
      if (harnessId === "*" || harnessId === harness.id) applyModelOverride(harness, modelId, raw, harnessId !== "*");
    }
  }
  return { ...catalog, harnesses, ...(diagnostics.length > 0 ? { diagnostics } : {}) };
}

function withHarnessConfig(harness: CatalogHarness, config: unknown): CatalogHarness {
  const copy: CatalogHarness = {
    ...harness,
    models: harness.models.map((model) => ({ ...model })),
  };
  if (!isRecord(config)) return copy;
  if (typeof config.name === "string" && config.name.trim()) copy.name = config.name.trim();
  if (typeof config.defaultModel === "string" && config.defaultModel) copy.defaultModel = config.defaultModel;
  return copy;
}

function orderOf(config: unknown, index: number): number {
  return isRecord(config) && typeof config.order === "number" && Number.isFinite(config.order)
    ? config.order - 0.5
    : index;
}

/** A known model takes the fields; an unknown one is added, but only to a harness the key names
 *  directly (a "*" key never invents a model in every harness). */
function applyModelOverride(
  harness: CatalogHarness,
  modelId: string,
  raw: Record<string, unknown>,
  add: boolean,
): void {
  const index = harness.models.findIndex((model) => model.id === modelId || model.aliases?.includes(modelId));
  if (raw.hidden === true) {
    if (index >= 0) harness.models.splice(index, 1);
    return;
  }
  const fields = modelFields(raw);
  if (index >= 0) harness.models[index] = { ...harness.models[index]!, ...fields };
  else if (add) {
    const name = fields.name ?? modelId;
    harness.models.push({ id: modelId, shortName: name, ...fields, name });
  }
}

function modelFields(raw: Record<string, unknown>): Partial<HarnessModel> {
  const fields: Partial<HarnessModel> = {};
  for (const key of ["name", "shortName", "family", "provider"] as const)
    if (typeof raw[key] === "string" && (raw[key] as string).trim()) fields[key] = (raw[key] as string).trim();
  if (Array.isArray(raw.efforts))
    fields.efforts = EFFORT_ORDER.filter((effort) => (raw.efforts as unknown[]).includes(effort));
  if (typeof raw.defaultEffort === "string" && EFFORT_ORDER.includes(raw.defaultEffort as EffortValue))
    fields.defaultEffort = raw.defaultEffort as EffortValue;
  if (typeof raw.fast === "boolean") fields.fast = raw.fast;
  if (typeof raw.contextWindow === "number" && Number.isInteger(raw.contextWindow) && raw.contextWindow > 0)
    fields.contextWindow = raw.contextWindow;
  return fields;
}

export type PickerInputs = {
  catalog: ModelCatalog;
  /** cmux.json `agentPane.models` (unchecked); it wins over the catalog and declared metadata. */
  user?: unknown;
  /** acpmux's harnesses and probed models (snapshot.catalog), each with its `family` when known. */
  acpmux: AcpmuxCatalog;
  /** The attached session: its harness and live config options win for effort and fast mode. */
  session?: { harness?: string; configOptions?: ConfigOptions };
  provisional?: boolean;
};

/** Joins the catalog with what acpmux reports (CONTRACT section 3, join rules 1-6). */
export function buildPickerCatalog({
  catalog,
  user,
  acpmux,
  session,
  provisional = false,
}: PickerInputs): PickerCatalog {
  // A chat folder's own profiles stay out of the join: the picker lists them on their own, and a
  // folder profile must never stand in for a catalog harness of its family.
  acpmux = acpmux.filter((entry) => !entry.folder);
  const layered = applyUserLayer(catalog, user);
  const join: Join = { catalog: layered, session, overrides: userOverrides(user) };
  const hidden = hiddenHarnesses(user);
  const covered = new Set<string>();
  const harnesses = layered.harnesses.map((harness) => {
    const members = acpmux.filter((entry) => harness.families.includes(familyOf(entry)));
    for (const member of members) covered.add(member.id);
    return catalogHarness(harness, members, join);
  });
  // A profile whose family a hidden catalog harness covers stays hidden with it.
  for (const harness of catalog.harnesses)
    if (hidden.has(harness.id))
      for (const entry of acpmux) if (harness.families.includes(familyOf(entry))) covered.add(entry.id);
  for (const entry of acpmux) {
    if (!covered.has(entry.id) && !hidden.has(entry.id)) harnesses.push(uncataloguedHarness(entry, join));
  }
  return { harnesses, provisional };
}

type Join = {
  catalog: ModelCatalog;
  session: PickerInputs["session"];
  overrides: Record<string, Record<string, unknown>>;
};

function userOverrides(user: unknown): Join["overrides"] {
  const overrides = isRecord(user) && isRecord(user.overrides) ? user.overrides : {};
  return Object.fromEntries(
    Object.entries(overrides).filter((entry): entry is [string, Record<string, unknown>] => isRecord(entry[1])),
  );
}

function hiddenHarnesses(user: unknown): Set<string> {
  const config = isRecord(user) && isRecord(user.harnesses) ? user.harnesses : {};
  return new Set(
    Object.entries(config)
      .filter(([, value]) => isRecord(value) && value.hidden === true)
      .map(([id]) => id),
  );
}

/** Catalog values, then what the profile declared, then the user's override fields. */
function layeredModel(
  model: HarnessModel,
  harnessId: string,
  probe: AcpmuxModel | undefined,
  join: Join,
): HarnessModel {
  // A profile declares metadata, not the model's identity: its name and provider stay the catalog's.
  const {
    name: _name,
    provider: _provider,
    ...declared
  } = probe ? modelFields(probe as unknown as Record<string, unknown>) : {};
  const user = {
    ...join.overrides[`*/${model.id}`],
    ...join.overrides[`${harnessId}/${model.id}`],
  };
  return { ...model, ...declared, ...modelFields(user) };
}

function catalogHarness(harness: CatalogHarness, members: AcpmuxHarness[], join: Join): PickerHarness {
  const { catalog, session } = join;
  const chosen =
    members.find((entry) => entry.id === session?.harness) ??
    members.find((entry) => entry.id === harness.id) ??
    members[0];
  const probed = chosen?.models ?? [];
  const listed = harness.modelSource === "catalog" ? harness.models : [];
  const models: PickerModel[] = listed.map((model) => {
    const probe = probedMatch(model, probed);
    return pickerModel(layeredModel(model, harness.id, probe, join), catalog, probe?.unavailable);
  });
  for (const probe of probed) {
    if (listed.some((model) => probeMatches(model, probe.id))) continue;
    if (isHiddenByUser(harness.id, probe.id, join)) continue;
    models.push(probedModel(probe, harness.id, join));
  }
  const live = session?.harness !== undefined && chosen?.id === session.harness ? session.configOptions : undefined;
  return {
    id: harness.id,
    name: harness.name,
    brand: harness.brand,
    acpmuxHarness: chosen?.id ?? null,
    installed: chosen !== undefined,
    pickable:
      harness.pickable !== false &&
      harness.kind !== "terminal" &&
      harness.kind !== "unknown" &&
      (chosen === undefined || entryPickable(chosen)),
    ...(chosen?.unavailable ? { unavailable: chosen.unavailable } : {}),
    ...(harness.defaultModel ? { defaultModel: harness.defaultModel } : {}),
    models: live ? models.map((model) => withLiveOptions(model, live)) : models,
  };
}

function uncataloguedHarness(entry: AcpmuxHarness, join: Join): PickerHarness {
  const live = entry.id === join.session?.harness ? join.session.configOptions : undefined;
  const models = entry.models
    .filter((probe) => !isHiddenByUser(entry.id, probe.id, join))
    .map((probe) => probedModel(probe, entry.id, join));
  const declaredBrand = entry.icon ? agentBrand(entry.icon) : undefined;
  const iconUrl = entry.icon && !declaredBrand && isIconFile(entry.icon) ? entry.icon : undefined;
  return {
    id: entry.id,
    name: agentName(entry.id, entry.name),
    brand: declaredBrand ?? agentBrand(entry.id) ?? null,
    ...(iconUrl ? { iconUrl } : {}),
    acpmuxHarness: entry.id,
    installed: true,
    pickable: entryPickable(entry),
    ...(entry.unavailable ? { unavailable: entry.unavailable } : {}),
    models: live ? models.map((model) => withLiveOptions(model, live)) : models,
  };
}

function pickerModel(model: HarnessModel, catalog: ModelCatalog, unavailable?: string): PickerModel {
  const info = model.ref ? catalog.models[model.ref] : undefined;
  const providerName = model.provider ? catalog.providers[model.provider]?.name : undefined;
  const contextWindow = model.contextWindow ?? info?.contextWindow;
  const status = model.status ?? info?.status;
  return {
    id: model.id,
    name: model.name,
    shortName: model.shortName || model.name,
    ...(model.family ? { family: model.family } : {}),
    ...(providerName ? { providerName } : {}),
    efforts: model.efforts ?? [],
    ...(model.defaultEffort ? { defaultEffort: model.defaultEffort } : {}),
    fast: model.fast === true,
    ...(contextWindow ? { contextWindow } : {}),
    ...(info?.reasoning !== undefined ? { reasoning: info.reasoning } : {}),
    ...(info?.input ? { input: info.input } : {}),
    ...(status ? { status } : {}),
    ...(unavailable ? { unavailable } : {}),
    searchText: [model.id, model.name, model.family, providerName, ...(model.aliases ?? [])]
      .filter(Boolean)
      .join(" ")
      .toLowerCase(),
  };
}

/** A model acpmux probed that the catalog does not list: described by its ref ("provider/model",
 *  as OpenCode and Pi report it) when the catalog knows it, else by the name the harness gave. */
function probedModel(probe: AcpmuxModel, harnessId: string, join: Join): PickerModel {
  const info = join.catalog.models[probe.id];
  const provider = probe.id.includes("/") ? probe.id.slice(0, probe.id.indexOf("/")) : undefined;
  const name = info?.name ?? probe.name ?? probe.id;
  const base: HarnessModel = {
    id: probe.id,
    ...(info ? { ref: probe.id } : {}),
    name,
    shortName: name,
    ...(provider ? { provider } : {}),
    ...(info?.family ? { family: info.family } : {}),
  };
  return pickerModel(layeredModel(base, harnessId, probe, join), join.catalog, probe.unavailable);
}

function isHiddenByUser(harnessId: string, modelId: string, join: Join): boolean {
  return join.overrides[`${harnessId}/${modelId}`]?.hidden === true || join.overrides[`*/${modelId}`]?.hidden === true;
}

/** A host-served icon file: an http(s) or cmux page URL, or an absolute path the host serves. */
function isIconFile(icon: string): boolean {
  return /^(?:https?:|cmux-[a-z-]+:)\/\//.test(icon) || icon.startsWith("/");
}

function probedMatch(model: HarnessModel, probed: AcpmuxModel[]): AcpmuxModel | undefined {
  return probed.find((probe) => probeMatches(model, probe.id));
}

function probeMatches(model: HarnessModel, id: string): boolean {
  return model.id === id || (model.aliases?.includes(id) ?? false);
}

/** The session's own effort and fast options are the truth for the model it runs. */
function withLiveOptions(model: PickerModel, options: ConfigOptions): PickerModel {
  const effort = options.find(
    (option) => option.category === "thought_level" || option.id === "effort" || option.id === "reasoning_effort",
  );
  const efforts = effort?.options
    ?.map((choice) => choice.value)
    .filter((value): value is EffortValue => EFFORT_ORDER.includes(value as EffortValue));
  const fast = options.some((option) => option.id === "fast" || option.id === "fast_mode");
  return {
    ...model,
    ...(efforts && efforts.length > 0 ? { efforts } : {}),
    ...(fast ? { fast: true } : {}),
  };
}

function familyOf(entry: AcpmuxHarness): string {
  return (entry as AcpmuxHarness & { family?: string }).family ?? agentKey(entry.id) ?? entry.id;
}

function isCatalogHarness(value: unknown): value is CatalogHarness {
  return (
    isRecord(value) &&
    typeof value.id === "string" &&
    typeof value.name === "string" &&
    Array.isArray(value.families) &&
    Array.isArray(value.models)
  );
}

function entryPickable(entry: AcpmuxHarness): boolean {
  const value = entry as AcpmuxHarness & { pickable?: unknown; kind?: unknown };
  return value.pickable !== false && value.kind !== "terminal" && value.kind !== "unknown";
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
