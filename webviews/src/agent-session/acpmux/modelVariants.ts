// One row per model in the model menu (Lawrence 2026-10-22, an OpenCode chat's menu listing "DeepSeek
// V4 Pro [New]", "OpenRouter/DeepSeek V4 Pro", "DeepSeek/DeepSeek V4 Pro" and more: "spacing + needs
// search", "we should just have a standard model picker"). A harness that routes to several providers
// (OpenCode, Pi) reports one model per provider, "provider/model". Those rows are one model: the
// menu lists it once and offers its providers as a second choice. Pure functions; no React.

/// A row the grouping reads: its id ("openrouter/deepseek/deepseek-v4-pro") and its name.
export type VariantModel = { id: string; name: string };

/// A provider's offer of a model: the row it is, and the provider's name.
export type ProviderOffer<T> = { model: T; provider: string };

/// A model as the menu lists it: `model` is the row a pick lands (the running provider's, else the
/// first listed), `name` the model's name without a provider, `tag` a bracketed note the name
/// carried ("New"), `offers` every provider's row, and `ids` every original catalog ID, including aliases.
export type ModelGroup<T> = {
  model: T;
  name: string;
  tag?: string;
  offers: ProviderOffer<T>[];
  count: number;
  ids: string[];
};

/// Providers' names as they write them; any other is its id, capitalized.
const PROVIDER_NAMES: Record<string, string> = {
  anthropic: "Anthropic",
  deepseek: "DeepSeek",
  google: "Google",
  groq: "Groq",
  mistral: "Mistral",
  moonshot: "Moonshot",
  openai: "OpenAI",
  opencode: "OpenCode",
  openrouter: "OpenRouter",
  qwen: "Qwen",
  together: "Together",
  xai: "xAI",
  zai: "Z.ai",
};

const BRACKET_TAG = /\s*\[([^\]]+)\]\s*$/;

/// Who serves a row and what model it is: `provider` (absent for a bare id), `key` (the model's id
/// without any provider path, which rows of one model share) and the name without a provider prefix
/// ("OpenRouter/DeepSeek V4 Pro" is "DeepSeek V4 Pro") or bracketed tag.
export function providerOf(model: VariantModel): {
  provider?: string;
  key: string;
  name: string;
  tag?: string;
} {
  const parts = model.id.split("/");
  const id = parts.length > 1 ? parts[0]! : undefined;
  const slash = model.name.lastIndexOf("/");
  const bare = slash > 0 ? model.name.slice(slash + 1).trim() : model.name.trim();
  const tag = BRACKET_TAG.exec(bare)?.[1];
  // The route prefix is authoritative. Names can carry an owner ("Qwen/Coder 3")
  // that must never be shown as the provider (OpenRouter).
  const provider = id ? (PROVIDER_NAMES[id.toLowerCase()] ?? id[0]!.toUpperCase() + id.slice(1)) : undefined;
  return {
    ...(provider ? { provider } : {}),
    key: (parts.at(-1) ?? model.id).toLowerCase(),
    name: bare.replace(BRACKET_TAG, ""),
    ...(tag ? { tag } : {}),
  };
}

/// The owner a row's id names between its provider and its model ("openrouter/qwen/coder-3" is
/// "qwen"); a "provider/model" id names none.
const ownerOf = (id: string): string | undefined => {
  const parts = id.toLowerCase().split("/");
  return parts.length > 2 ? parts.slice(1, -1).join("/") : undefined;
};

/// `models` as one row per model, in order of each model's first row. Only rows that name a
/// provider join, only rows of one owner join, and only one row per provider: two bare ids are two
/// models, and so are "openrouter/qwen/m" and "together/mistral/m". A row that names no owner
/// ("groq/m") joins the one owner its model has, or the owner its provider is ("mistral/m"); with
/// several and neither, it is its own model. `current` is the running row's id: its group lands it.
/// A provider's row is named without the provider ("Z.ai/GLM 5.3" is "GLM 5.3"); the menu names the
/// provider beside it. When one provider repeats a route, its offer is the available row, the running
/// one first.
export function groupVariants<T extends VariantModel>(models: readonly T[], current?: string): ModelGroup<T>[] {
  const rows = models.map((model) => ({ model, ...providerOf(model), owner: ownerOf(model.id) }));
  // Every owner each model id is named under.
  const owners = new Map<string, Set<string>>();
  for (const row of rows)
    if (row.provider && row.owner) owners.set(row.key, (owners.get(row.key) ?? new Set<string>()).add(row.owner));
  // The model a row is: its id's last part and its owner, or undefined when that cannot be told.
  const identity = (row: (typeof rows)[number]): string | undefined => {
    if (!row.provider) return undefined;
    const named = owners.get(row.key) ?? new Set<string>();
    const by = row.model.id.split("/")[0]!.toLowerCase();
    const owner = row.owner ?? (named.size <= 1 ? ([...named][0] ?? "") : named.has(by) ? by : undefined);
    return row.key + "\u0000" + (owner === undefined ? "provider:" + by : owner);
  };
  const groups: ModelGroup<T>[] = [];
  const byIdentity = new Map<string, ModelGroup<T>>();
  const byBareId = new Map<string, ModelGroup<T>>();
  for (const row of rows) {
    const { model, provider, name, tag } = row;
    const offer = { model, provider: provider ?? "" };
    const id = identity(row);
    const bareId = id === undefined ? row.model.id : undefined;
    const joined = id === undefined ? byBareId.get(bareId!) : byIdentity.get(id);
    if (joined) {
      joined.count += 1;
      joined.ids.push(model.id);
      const providerId = row.model.id.split("/")[0]!.toLowerCase();
      const duplicateIndex = joined.offers.findIndex(
        (each) => each.model.id.split("/")[0]!.toLowerCase() === providerId,
      );
      if (duplicateIndex < 0) {
        joined.offers.push(offer);
      } else {
        const existing = joined.offers[duplicateIndex]!;
        const existingUnavailable = Boolean((existing.model as VariantModel & { unavailable?: unknown }).unavailable);
        const incomingUnavailable = Boolean((model as T & { unavailable?: unknown }).unavailable);
        const existingCurrent = existing.model.id === current;
        const incomingCurrent = model.id === current;
        const rank = (current: boolean, unavailable: boolean) => (unavailable ? 0 : 2) + (current ? 1 : 0);
        const existingRank = rank(existingCurrent, existingUnavailable);
        const incomingRank = rank(incomingCurrent, incomingUnavailable);
        if (incomingRank > existingRank) joined.offers[duplicateIndex] = offer;
      }
      if (model.id === current) joined.model = model;
      joined.tag ??= tag;
      continue;
    }
    const next: ModelGroup<T> = {
      model,
      name: provider ? name : model.name.replace(BRACKET_TAG, ""),
      ...(tag ? { tag } : {}),
      offers: [offer],
      count: 1,
      ids: [model.id],
    };
    groups.push(next);
    if (id !== undefined && !byIdentity.has(id)) byIdentity.set(id, next);
    if (bareId !== undefined && !byBareId.has(bareId)) byBareId.set(bareId, next);
  }
  return groups;
}
