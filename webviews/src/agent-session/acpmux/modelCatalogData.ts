import { isDefaultChoice } from "./defaultChoice";
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

export type EffortValue = "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max" | "ultra";
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
  inlineFast?: boolean;
  serviceTiers?: (string | { id: string; name?: string; description?: string })[];
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
  /** Where to install and set the harness up (the Harnesses page's Install…). */
  docsUrl?: string;
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
  inlineFast?: boolean;
  serviceTiers?: (string | { id: string; name?: string; description?: string })[];
  contextWindow?: number;
  reasoning?: boolean;
  input?: string[];
  status?: ModelStatus;
  unavailable?: string;
  /** The catalog release an alias row stands for; `id` is the alias the harness offers. */
  release?: string;
  /** What the profile's declaration or the user's override set: the session's options keep it. */
  own?: Own;
  searchText: string;
};

/** The fields a profile declared or the user overrode, over the catalog's. */
type Own = { efforts?: true; fast?: true };

export type PickerHarness = {
  /** The installed harness's own model-menu order, separate from the full catalog. */
  topModels?: string[];
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
  /** `unavailable` is only a failed model probe: the harness may still run. */
  probeFailed?: boolean;
  defaultModel?: string;
  docsUrl?: string;
  /** The catalog harness whose releases a profile the catalog does not map runs ("claude-sr2" runs
   *  Claude Code's): its curated top models apply, and its releases name the profile's models. */
  kin?: string;
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

const EFFORT_ORDER: readonly EffortValue[] = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"];

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
  if (typeof raw.inlineFast === "boolean") fields.inlineFast = raw.inlineFast;
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
  /** The attached session: its harness and live config options win for effort and fast mode.
   *  `model` is the model it reports running (summary.model), also when no model option names it. */
  session?: { harness?: string; model?: string; configOptions?: ConfigOptions };
  /** Profiles whose chats' last turn completed, the latest first (workedProfiles). */
  worked?: string[];
  provisional?: boolean;
};

/** The profiles of the chats whose last turn completed, most recently updated first, each once. */
export function workedProfiles(sessions: readonly { harness?: string; updatedAt?: number; worked?: boolean }[]) {
  return [
    ...new Set(
      sessions
        .filter((session) => session.worked && session.harness)
        .sort((a, b) => (b.updatedAt ?? 0) - (a.updatedAt ?? 0))
        .map((session) => session.harness!),
    ),
  ];
}

/** Joins the catalog with what acpmux reports (CONTRACT section 3, join rules 1-6). */
export function buildPickerCatalog({
  catalog,
  user,
  acpmux,
  session,
  worked = [],
  provisional = false,
}: PickerInputs): PickerCatalog {
  // A chat folder's own profiles stay out of the join: the picker lists them on their own, and a
  // folder profile must never stand in for a catalog harness of its family.
  acpmux = acpmux.filter((entry) => !entry.folder);
  const layered = applyUserLayer(catalog, user);
  const join: Join = {
    catalog: layered,
    sourceCatalog: catalog,
    session,
    worked,
    overrides: userOverrides(user),
    releaseNames: releaseNames(catalog),
  };
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
  /** The unlayered catalog keeps alias declarations that hidden overrides remove from `catalog`. */
  sourceCatalog: ModelCatalog;
  session: PickerInputs["session"];
  worked: string[];
  overrides: Record<string, Record<string, unknown>>;
  /** Each catalog release's own names, before the user layer renames it: what a harness alias's
   *  reported name is matched against (`foldAliases`). */
  releaseNames: Map<string, string[]>;
};

function releaseNames(catalog: ModelCatalog): Join["releaseNames"] {
  const names = new Map<string, string[]>();
  for (const harness of catalog.harnesses)
    for (const model of harness.models)
      names.set(model.id, [...(names.get(model.id) ?? []), model.name, model.shortName].filter(Boolean));
  return names;
}

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
): HarnessModel & { own?: Own } {
  // A profile declares metadata, not the model's identity: its name and provider stay the catalog's.
  const {
    name: _name,
    provider: _provider,
    ...declared
  } = probe ? modelFields(probe as unknown as Record<string, unknown>) : {};
  // An override of a catalog alias ("<harness>/opus") is one of its release, as applyUserLayer has it.
  const user = Object.assign(
    {},
    ...[...(model.aliases ?? []), model.id].flatMap((id) => [
      join.overrides[`*/${id}`],
      join.overrides[`${harnessId}/${id}`],
    ]),
  ) as Record<string, unknown>;
  const fields = modelFields(user);
  const own: Own = {
    ...(model as { own?: Own }).own,
    ...(declared.efforts || fields.efforts ? { efforts: true } : {}),
    ...(declared.fast !== undefined || fields.fast !== undefined ? { fast: true } : {}),
  };
  return { ...model, ...declared, ...fields, ...(own.efforts || own.fast ? { own } : {}) };
}

function catalogHarness(harness: CatalogHarness, members: AcpmuxHarness[], join: Join): PickerHarness {
  const { session } = join;
  // The shown chat's profile, else the one this person's chats last finished a turn on (claude-sr
  // where only the subrouter is signed in), never a bare harness its chats only failed on.
  const chosen =
    members.find((entry) => entry.id === session?.harness) ??
    join.worked
      .map((id) => members.find((entry) => entry.id === id && (!entry.unavailable || entry.probeFailed)))
      .find((entry) => entry !== undefined) ??
    members.find((entry) => entry.id === harness.id) ??
    members[0];
  const probed = chosen?.models ?? [];
  const listed = harness.modelSource === "catalog" ? harness.models : [];
  const live = session?.harness !== undefined && chosen?.id === session.harness ? session.configOptions : undefined;
  const reported = reportedNames(probed, live);
  const hiddenReleases = hiddenReleaseIds(harness.id, harness.id, reported, join);
  const models: PickerModel[] = listed.map((model) => listedModel(model, harness.id, probed, join));
  for (const probe of probed) {
    if (listed.some((model) => model.id === probe.id)) continue;
    if (isHiddenByUser(harness.id, probe.id, join)) continue;
    if (hiddenReleases.has(probe.id)) continue;
    models.push(probedModel(probe, harness.id, join));
  }
  addSessionModels(models, live, harness.id, listed, join, hiddenReleases);
  const releases = models.filter((model) => listed.some((pinned) => pinned.id === model.id));
  const runs = chosen?.id === session?.harness ? runningModel(session, live) : undefined;
  const offered = foldAliases(models, releases, runs, reported, join, (release, alias) =>
    aliasRow(listed, release, alias, harness.id, probed, join),
  );
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
    ...(chosen?.probeFailed ? { probeFailed: true } : {}),
    ...(harness.defaultModel ? { defaultModel: harness.defaultModel } : {}),
    ...(harness.docsUrl ? { docsUrl: harness.docsUrl } : {}),
    topModels: menuModels(chosen?.topModels, live, offered, reported),
    models: live ? offered.map((model) => withLiveOptions(model, live)) : offered,
  };
}

function uncataloguedHarness(entry: AcpmuxHarness, join: Join): PickerHarness {
  const live = entry.id === join.session?.harness ? join.session.configOptions : undefined;
  // A profile of a catalogued agent ("claude-sr2" is Claude Code) runs that agent's releases: they
  // name the release its session pins, and the aliases the agent names as one fold into it.
  const key = agentKey(familyOf(entry));
  const kin = join.catalog.harnesses.find(
    (harness) => harness.modelSource === "catalog" && key !== undefined && harness.families.includes(key),
  );
  const reported = reportedNames(entry.models, live);
  const hiddenReleases = hiddenReleaseIds(entry.id, kin?.id, reported, join);
  // A release the user hid here, by its id, a catalog alias or an alias the harness reports as it,
  // is not one of this profile's releases (applyUserLayer drops it so from its own harness).
  const listed = (kin?.models ?? []).filter(
    (model) =>
      ![...(model.aliases ?? []), model.id].some((id) => isHiddenByUser(entry.id, id, join)) &&
      ![...reported].some(([id, name]) => isHiddenByUser(entry.id, id, join) && namesRelease(name, model, join)),
  );
  const models = entry.models
    .filter((probe) => !isHiddenByUser(entry.id, probe.id, join) && !hiddenReleases.has(probe.id))
    .map((probe) => probedModel(probe, entry.id, join));
  addSessionModels(models, live, entry.id, listed, join, hiddenReleases);
  const releases = listed.map((model) => listedModel(model, entry.id, entry.models, join));
  const runs = entry.id === join.session?.harness ? runningModel(join.session, live) : undefined;
  const offered = kin
    ? foldAliases(models, releases, runs, reported, join, (release, alias) =>
        aliasRow(listed, release, alias, entry.id, entry.models, join),
      )
    : models;
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
    ...(entry.probeFailed ? { probeFailed: true } : {}),
    ...(kin ? { kin: kin.id } : {}),
    topModels: menuModels(entry.topModels, live, offered, reported),
    models: live ? offered.map((model) => withLiveOptions(model, live)) : offered,
  };
}

/** Keep the harness menu's order after aliases fold into their catalog releases. */
function menuModels(
  top: readonly string[] | undefined,
  options: ConfigOptions | undefined,
  models: PickerModel[],
  reported: Map<string, string>,
): string[] | undefined {
  const option = options?.find((choice) => choice.category === "model" || choice.id === "model");
  const ids = top ?? option?.options?.map((choice) => choice.value);
  if (!ids) return undefined;
  return [
    ...new Set(
      ids.flatMap((id) => {
        const model =
          models.find((choice) => choice.id === id || choice.release === id) ??
          models.find((choice) => reported.get(id) && nameKey(reported.get(id)) === nameKey(choice.name));
        return model && !isDefaultChoice(model) ? [model.id] : [];
      }),
    ),
  ];
}

/**
 * One catalog model, by its own id. A catalog alias is never used to guess what a harness alias
 * runs: that depends on the installed harness (Claude Code 2.1.287's `haiku` is Haiku 4.5,
 * 2.1.295's is Haiku 5.5), so only the harness's own report names an alias (`foldAliases`).
 */
function listedModel(model: HarnessModel, harnessId: string, probed: AcpmuxModel[], join: Join): PickerModel {
  const probe = probed.find((candidate) => candidate.id === model.id);
  return pickerModel(layeredModel(model, harnessId, probe, join), join.catalog, probe?.unavailable);
}

/** The model the session runs: its model option's value, else the model it reports (a session can
 *  report `summary.model` with no model option, direct.ts). */
function runningModel(session: Join["session"], options: ConfigOptions | undefined): string | undefined {
  const current = options?.find((option) => option.category === "model" || option.id === "model")?.currentValue;
  if (typeof current === "string" && current) return current;
  return session?.model || undefined;
}

/** "Claude Opus 5.5" and "Opus 5.5" name one model. */
const nameKey = (name: string | undefined) =>
  name
    ?.replace(/^claude\s+/i, "")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();

/** The names the harness itself gives its models (its probe, then its session's model option),
 *  by id: a user's rename of an alias does not change which release it is. */
function reportedNames(probes: readonly AcpmuxModel[], options: ConfigOptions | undefined): Map<string, string> {
  const names = new Map<string, string>();
  for (const probe of probes) if (probe.name) names.set(probe.id, probe.name);
  const option = options?.find((candidate) => candidate.category === "model" || candidate.id === "model");
  for (const choice of option?.options ?? [])
    if (choice.name && !names.has(choice.value)) names.set(choice.value, choice.name);
  return names;
}

/** The harness's name for a model is the catalog's name for this release (a model the user added
 *  has only the names the user gave it). */
function namesRelease(
  name: string | undefined,
  release: { id: string; name: string; shortName: string },
  join: Join,
): boolean {
  const key = nameKey(name);
  if (!key) return false;
  const own = join.releaseNames.get(release.id) ?? [release.name, release.shortName];
  return own.some((candidate) => nameKey(candidate) === key);
}

/**
 * One row per model. A model the harness reports under an alias and names as a catalog release
 * ("opus" named "Opus 5.5", from Claude Code's initialize reply) is that release: one row, the
 * alias (so a pick follows the harness's newest), with the release's catalog metadata. A session
 * that runs the pinned release itself (`current`) keeps the release's row, checked, and the alias
 * folds into it (Leo 2026-10-21: Opus 5.5 was listed twice, the alias and the release the chat runs).
 * `releases` are the catalog's rows for the harness's releases.
 */
function foldAliases(
  models: PickerModel[],
  releases: PickerModel[],
  current: string | undefined,
  reported: Map<string, string>,
  join: Join,
  asAlias: (release: PickerModel, alias: PickerModel) => PickerModel,
): PickerModel[] {
  const releaseIds = new Set(releases.map((model) => model.id));
  // release id -> the alias that is it (the first alias the harness names as it)
  const takenBy = new Map<string, PickerModel>();
  for (const model of models) {
    if (releaseIds.has(model.id)) continue;
    const name = reported.get(model.id) ?? model.name;
    const release = releases.find((candidate) => !takenBy.has(candidate.id) && namesRelease(name, candidate, join));
    if (release) takenBy.set(release.id, model);
  }
  const aliasFor = new Map([...takenBy].map(([release, alias]) => [alias.id, release]));
  const rowOf = new Map(models.map((model) => [model.id, model]));
  // The running release keeps its own id (so it stays the checked row), with what is declared and
  // overridden for the alias it stands for: the same model, the same limits.
  const asRunning = (row: PickerModel, id: string): PickerModel => {
    const { release: _release, ...running } = row;
    return { ...running, id };
  };
  const folded = models.flatMap((model): PickerModel[] => {
    const releaseId = aliasFor.get(model.id);
    if (releaseId !== undefined) {
      // Where the release has a row, that row stands for both (below); else the alias takes the
      // release's catalog row here, under the release's id when the session runs the release (a
      // direct session reports `summary.model` with no model option, and the probe lists the alias).
      if (rowOf.has(releaseId)) return [];
      const row = asAlias(
        releases.find((release) => release.id === releaseId)!,
        model,
      );
      return [releaseId === current ? asRunning(row, releaseId) : row];
    }
    const alias = takenBy.get(model.id);
    if (!alias) return [model];
    const row = asAlias(model, alias);
    return [model.id === current ? asRunning(row, model.id) : row];
  });
  // A release the session runs that nothing lists still gets its row, so the running model is shown.
  const running = releases.find((release) => release.id === current);
  return running && !folded.some((model) => model.id === running.id) ? [...folded, running] : folded;
}

/**
 * The release's row under the alias's id: the release's catalog metadata (and what is declared and
 * overridden for the release), then what the harness declares for the alias and the user's
 * overrides of the alias on top, so an alias the user limited (`<harness>/opus`: no fast, one
 * effort) stays limited once it takes the release's row.
 */
function aliasRow(
  listed: HarnessModel[],
  release: PickerModel,
  alias: PickerModel,
  harnessId: string,
  probed: AcpmuxModel[],
  join: Join,
): PickerModel {
  const pinned = listed.find((model) => model.id === release.id);
  if (!pinned)
    return {
      ...release,
      id: alias.id,
      release: release.id,
      ...(alias.unavailable ? { unavailable: alias.unavailable } : {}),
      searchText: `${alias.id} ${release.searchText}`,
    };
  const asRelease = layeredModel(
    pinned,
    harnessId,
    probed.find((probe) => probe.id === pinned.id),
    join,
  );
  const asAlias = layeredModel(
    { ...asRelease, id: alias.id },
    harnessId,
    probed.find((probe) => probe.id === alias.id),
    join,
  );
  const row = pickerModel(asAlias, join.catalog, alias.unavailable);
  return { ...row, release: release.id, searchText: `${alias.id} ${row.searchText}` };
}

/**
 * The harness is the authority: every model the running session's own model option lists (and the
 * one it runs) is offered, also when neither the catalog nor acpmux's model list has it.
 */
function addSessionModels(
  models: PickerModel[],
  options: ConfigOptions | undefined,
  harnessId: string,
  listed: HarnessModel[],
  join: Join,
  hiddenReleases: Set<string> = new Set(),
): void {
  const option = options?.find((candidate) => candidate.category === "model" || candidate.id === "model");
  if (!option) return;
  const choices: { id: string; name?: string }[] = (option.options ?? []).map((choice) => ({
    id: choice.value,
    name: choice.name || undefined,
  }));
  if (option.currentValue) choices.push({ id: option.currentValue });
  for (const choice of choices) {
    if (!choice.id || models.some((model) => model.id === choice.id)) continue;
    if (isHiddenByUser(harnessId, choice.id, join)) continue;
    if (hiddenReleases.has(choice.id)) continue;
    const pinned = listed.find((model) => model.id === choice.id);
    models.push(
      pinned
        ? pickerModel(layeredModel(pinned, harnessId, undefined, join), join.catalog)
        : probedModel({ id: choice.id, name: choice.name } as AcpmuxModel, harnessId, join),
    );
  }
}

function pickerModel(model: HarnessModel & { own?: Own }, catalog: ModelCatalog, unavailable?: string): PickerModel {
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
    ...(model.inlineFast === true ? { inlineFast: true } : {}),
    ...(model.serviceTiers ? { serviceTiers: model.serviceTiers } : {}),
    ...(contextWindow ? { contextWindow } : {}),
    ...(info?.reasoning !== undefined ? { reasoning: info.reasoning } : {}),
    ...(info?.input ? { input: info.input } : {}),
    ...(status ? { status } : {}),
    ...(unavailable ? { unavailable } : {}),
    ...(model.own ? { own: model.own } : {}),
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

/**
 * Hidden catalog aliases must also hide a concrete release probe that is reported alongside them.
 * The layered catalog has already removed that release, so use the source catalog's aliases here
 * before the probe loop can re-add it as an unlisted model.
 */
function hiddenReleaseIds(
  harnessId: string,
  sourceHarnessId: string | undefined,
  reported: Map<string, string>,
  join: Join,
): Set<string> {
  const source = join.sourceCatalog.harnesses.find((harness) => harness.id === sourceHarnessId);
  const hidden = new Set<string>();
  for (const model of source?.models ?? []) {
    const hiddenById = [...(model.aliases ?? []), model.id].some((id) => isHiddenByUser(harnessId, id, join));
    const hiddenByReportedAlias = [...reported].some(
      ([id, name]) => isHiddenByUser(harnessId, id, join) && namesRelease(name, model, join),
    );
    if (hiddenById || hiddenByReportedAlias) hidden.add(model.id);
  }
  return hidden;
}

/** A host-served icon file: an http(s) or cmux page URL, or an absolute path the host serves. */
function isIconFile(icon: string): boolean {
  return /^(?:https?:|cmux-[a-z-]+:)\/\//.test(icon) || icon.startsWith("/");
}

/** The session's own effort and fast options are the truth for the model it runs. */
function withLiveOptions(model: PickerModel, options: ConfigOptions): PickerModel {
  const effort = options.find(
    (option) => option.category === "thought_level" || option.id === "effort" || option.id === "reasoning_effort",
  );
  const offered = effort?.options
    ?.map((choice) => choice.value)
    .filter((value): value is EffortValue => EFFORT_ORDER.includes(value as EffortValue));
  // An adapter can list one set for every model (Claude Code's): the model's own levels bound it.
  // Levels the profile declared or the user set (none included) are only narrowed, never widened.
  const narrowed =
    offered && (model.efforts.length > 0 || model.own?.efforts)
      ? offered.filter((value) => model.efforts.includes(value))
      : offered;
  const efforts = narrowed && (narrowed.length > 0 || model.own?.efforts) ? narrowed : offered;
  // An adapter can offer fast mode for every model too (Claude Code's, honored on a few): a model
  // the catalog describes keeps its own, and so does one whose profile or user set it.
  const fast =
    !model.own?.fast &&
    model.efforts.length === 0 &&
    options.some((option) => option.id === "fast" || option.id === "fast_mode" || option.id === "fast-mode");
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
