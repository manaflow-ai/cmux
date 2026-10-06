// The model picker's model layer: which provider and family each catalog model
// belongs to, which model a provider or family lands on, and the order a level lists them in.
// Pure functions over the current harness's catalog and the viewer's recents; no React.
import type { Combo } from "./ComposerPickers";
import { isDefaultChoice } from "./defaultChoice";

export type CatalogModel = { id: string; name?: string };

export type TaxModel = {
  id: string;
  name: string;
  provider: string;
  family: string;
  /// Version numbers read from the name (else the id), compared newest first.
  version: number[];
  /// Position in the catalog, the tiebreak after the version.
  order: number;
};
export type TaxFamily = { key: string; name: string; provider: string; models: TaxModel[] };
export type TaxProvider = { name: string; families: TaxFamily[]; models: TaxModel[] };
export type Taxonomy = { providers: TaxProvider[]; models: TaxModel[]; byId: Map<string, TaxModel> };
/// The model and effort a pick lands on. No effort means keep whatever the agent runs.
export type Landing = { model: string; effort?: string };
/// What the session runs now; it counts as the most recent use.
export type Current = { model?: string; effort?: string };

const ANTHROPIC = "Anthropic";
const OPENAI = "OpenAI";

const capitalize = (word: string) => (word ? word[0]!.toUpperCase() + word.slice(1) : word);

/// The provider and family of one model. Known id shapes first (claude-opus-*, gpt-6-*, o3),
/// then the name; anything unknown is the harness's own, in a family named for its first word.
export function classify(model: CatalogModel, harnessName: string): { provider: string; family: string } {
  const id = model.id.toLowerCase();
  const name = (model.name || model.id).trim();
  const claude = /^claude-(?:[\d-]+-)?([a-z]+)/.exec(id);
  if (claude) return { provider: ANTHROPIC, family: capitalize(claude[1]!) };
  const anthropicName = /^(?:claude\s+)?(opus|sonnet|haiku|fable)\b/i.exec(name);
  if (anthropicName) return { provider: ANTHROPIC, family: capitalize(anthropicName[1]!.toLowerCase()) };
  if (id.startsWith("gpt-oss")) return { provider: OPENAI, family: "gpt-oss" };
  const gpt = /^gpt-(\d+)/.exec(id);
  if (gpt) return { provider: OPENAI, family: `GPT-${gpt[1]}` };
  const reasoning = /^o(\d+)(?:-|$)/.exec(id);
  if (reasoning) return { provider: OPENAI, family: `o${reasoning[1]}` };
  const gemini = /^gemini-(\d+)/.exec(id);
  if (gemini) return { provider: "Google", family: `Gemini ${gemini[1]}` };
  const first = (text: string) => text.split(/[\s\-_:/]+/)[0] ?? text;
  if (/^(?:mistral|devstral|codestral|magistral)/.test(id))
    return { provider: "Mistral", family: capitalize(first(id)) };
  if (id.startsWith("qwen")) return { provider: "Qwen", family: capitalize(first(id)) };
  if (id.startsWith("deepseek"))
    return { provider: "DeepSeek", family: capitalize(first(id).replace(/^deepseek/, "DeepSeek")) };
  if (/^(?:meta-)?llama/.test(id)) return { provider: "Meta", family: "Llama" };
  return { provider: harnessName, family: capitalize(first(name)) };
}

/// The version numbers in a model's name (else its id): "Opus 5.5" is [5, 5], "claude-opus-4-1" [4, 1].
export function versionOf(model: CatalogModel): number[] {
  const fromName = /\d+(?:\.\d+)*/.exec(model.name ?? "");
  if (fromName) return fromName[0].split(".").map(Number);
  return (model.id.match(/\d+/g) ?? []).map(Number);
}

/// Newest first: the higher version, then the earlier catalog entry.
export function newestFirst(a: TaxModel, b: TaxModel): number {
  const length = Math.max(a.version.length, b.version.length);
  for (let index = 0; index < length; index += 1) {
    const difference = (b.version[index] ?? -1) - (a.version[index] ?? -1);
    if (difference !== 0) return difference;
  }
  return a.order - b.order;
}

/// The current harness's catalog as providers of families of models, each in catalog order of first appearance.
/// The agent's default ("default") is left out.
export function buildTaxonomy(models: CatalogModel[], harnessName: string): Taxonomy {
  const providers: TaxProvider[] = [];
  const byId = new Map<string, TaxModel>();
  const all: TaxModel[] = [];
  models.forEach((model, order) => {
    // The agent's own default is no provider's model; the picker offers it as its own row.
    if (byId.has(model.id) || isDefaultChoice(model)) return;
    const { provider, family } = classify(model, harnessName);
    const entry: TaxModel = {
      id: model.id,
      name: model.name || model.id,
      provider,
      family,
      version: versionOf(model),
      order,
    };
    byId.set(model.id, entry);
    all.push(entry);
    let group = providers.find((candidate) => candidate.name === provider);
    if (!group) {
      group = { name: provider, families: [], models: [] };
      providers.push(group);
    }
    group.models.push(entry);
    let line = group.families.find((candidate) => candidate.name === family);
    if (!line) {
      line = { key: `${provider}\u0000${family}`, name: family, provider, models: [] };
      group.families.push(line);
    }
    line.models.push(entry);
  });
  for (const provider of providers) for (const family of provider.families) family.models.sort(newestFirst);
  return { providers, models: all, byId };
}

/// The one model of `models` a pick lands on: the current model, else the last used, else the newest.
export function defaultModel(models: TaxModel[], recents: Combo[], current: Current = {}): TaxModel | undefined {
  const within = (id?: string) => models.find((model) => model.id === id);
  return (
    within(current.model) ??
    recents.map((combo) => within(combo.model)).find(Boolean) ??
    [...models].sort(newestFirst)[0]
  );
}

/// A family's default: the current or last-used model in it, else its newest.
export function familyDefault(family: TaxFamily, recents: Combo[], current: Current = {}): TaxModel | undefined {
  return defaultModel(family.models, recents, current);
}

/// A provider's default: the current or last-used model it serves, else its first family's default.
export function providerDefault(provider: TaxProvider, recents: Combo[], current: Current = {}): TaxModel | undefined {
  const serves = (id?: string) => provider.models.some((model) => model.id === id);
  if (serves(current.model) || recents.some((combo) => serves(combo.model)))
    return defaultModel(provider.models, recents, current);
  const first = provider.families[0];
  return first ? familyDefault(first, recents, current) : undefined;
}

/// The effort a model lands with: its own current effort, else the one last used with it, else
/// the session's current effort, so a switch keeps the reasoning the viewer runs.
export function effortFor(model: string, recents: Combo[], current: Current = {}): string | undefined {
  if (model === current.model) return current.effort;
  return recents.find((combo) => combo.model === model && combo.effort)?.effort ?? current.effort;
}

/// Where a pick of `model` lands, its effort from the recents.
export function landOnModel(model: TaxModel, recents: Combo[], current: Current = {}): Landing {
  return { model: model.id, effort: effortFor(model.id, recents, current) };
}

/// Where picking a family lands: its default model, with that model's recent effort.
export function landOnFamily(family: TaxFamily, recents: Combo[], current: Current = {}): Landing | undefined {
  const model = familyDefault(family, recents, current);
  return model && landOnModel(model, recents, current);
}

/// Where picking a provider lands: its default model, with that model's recent effort.
export function landOnProvider(provider: TaxProvider, recents: Combo[], current: Current = {}): Landing | undefined {
  const model = providerDefault(provider, recents, current);
  return model && landOnModel(model, recents, current);
}

/// A level's models best first: the default, then other recently used ones, then the rest newest first.
export function rankModels(models: TaxModel[], recents: Combo[], current: Current = {}): TaxModel[] {
  const first = defaultModel(models, recents, current);
  const used: TaxModel[] = [];
  for (const combo of recents) {
    const model = models.find((candidate) => candidate.id === combo.model);
    if (model && model !== first && !used.includes(model)) used.push(model);
  }
  const rest = [...models].filter((model) => model !== first && !used.includes(model)).sort(newestFirst);
  return [...(first ? [first] : []), ...used, ...rest];
}

/// Families best first: the current one, then those with a recent model, then catalog order.
export function rankFamilies(families: TaxFamily[], recents: Combo[], current: Current = {}): TaxFamily[] {
  return rankByUse(families, (family) => family.models, recents, current);
}

/// Providers best first: the current one, then those with a recent model, then catalog order.
export function rankProviders(providers: TaxProvider[], recents: Combo[], current: Current = {}): TaxProvider[] {
  return rankByUse(providers, (provider) => provider.models, recents, current);
}

function rankByUse<T>(items: T[], models: (item: T) => TaxModel[], recents: Combo[], current: Current): T[] {
  const ids = [current.model, ...recents.map((combo) => combo.model)];
  const rank = (item: T) => {
    const at = ids.findIndex((id) => id && models(item).some((model) => model.id === id));
    return at < 0 ? ids.length : at;
  };
  return items
    .map((item, index) => ({ item, index, rank: rank(item) }))
    .sort((a, b) => a.rank - b.rank || a.index - b.index)
    .map((entry) => entry.item);
}

/// The rows a level shows before "More…": the first `shown`, unless only one would be left folded.
export function fold<T>(ranked: T[], shown: number, expanded: boolean): { visible: T[]; hidden: number } {
  if (expanded || ranked.length <= shown + 1) return { visible: ranked, hidden: 0 };
  return { visible: ranked.slice(0, shown), hidden: ranked.length - shown };
}

/// Models matching every word of `query` in their name, id, family or provider, best match first.
export function filterModels(taxonomy: Taxonomy, query: string): TaxModel[] {
  const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  if (words.length === 0) return taxonomy.models;
  const scored: { model: TaxModel; score: number }[] = [];
  for (const model of taxonomy.models) {
    const name = model.name.toLowerCase();
    const haystack = `${name} ${model.id.toLowerCase()} ${model.family.toLowerCase()} ${model.provider.toLowerCase()}`;
    if (!words.every((word) => haystack.includes(word))) continue;
    const score = name.startsWith(words[0]!) ? 0 : name.includes(words[0]!) ? 1 : 2;
    scored.push({ model, score });
  }
  return scored.sort((a, b) => a.score - b.score || newestFirst(a.model, b.model)).map((entry) => entry.model);
}

/// The viewer's recents that this harness's catalog can run, newest first, at most `limit`.
export function runnableRecents(
  recents: Combo[],
  taxonomy: Taxonomy,
  harness: string | undefined,
  limit: number,
): Combo[] {
  return recents.filter((combo) => combo.harness === harness && taxonomy.byId.has(combo.model)).slice(0, limit);
}
