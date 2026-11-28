// The model picker's model layer: which provider and family each catalog model
// belongs to, which model a provider or family lands on, and the order a level lists them in.
// Pure functions over the current harness's catalog and the viewer's recents; no React.
import type { Combo } from "./composerPickerModel";

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
  // Router ids name the vendor first ("z-ai/glm-5.3", "qwen/qwen3.7-flash"): the model part decides.
  const id = model.id.toLowerCase().replace(/^[a-z0-9.-]+\//, "");
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
  if (id.startsWith("glm")) return { provider: "Z.ai", family: "GLM" };
  if (id.startsWith("kimi")) return { provider: "Moonshot", family: "Kimi" };
  if (id.startsWith("minimax")) return { provider: "MiniMax", family: "MiniMax" };
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

/// The rows a level shows before "More…": the first `shown`, unless only one would be left folded.
export function fold<T>(ranked: T[], shown: number, expanded: boolean): { visible: T[]; hidden: number } {
  if (expanded || ranked.length <= shown + 1) return { visible: ranked, hidden: 0 };
  return { visible: ranked.slice(0, shown), hidden: ranked.length - shown };
}
