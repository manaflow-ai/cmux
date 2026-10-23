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
/// carried ("New"), and `offers` every provider's row, in list order (one, for a plain model).
export type ModelGroup<T> = { model: T; name: string; tag?: string; offers: ProviderOffer<T>[] };

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
  const named = slash > 0 ? model.name.slice(0, model.name.indexOf("/")).trim() : undefined;
  const bare = slash > 0 ? model.name.slice(slash + 1).trim() : model.name.trim();
  const tag = BRACKET_TAG.exec(bare)?.[1];
  const provider = id ? (named ?? PROVIDER_NAMES[id.toLowerCase()] ?? id[0]!.toUpperCase() + id.slice(1)) : undefined;
  return {
    ...(provider ? { provider } : {}),
    key: (parts.at(-1) ?? model.id).toLowerCase(),
    name: bare.replace(BRACKET_TAG, ""),
    ...(tag ? { tag } : {}),
  };
}

/// `models` as one row per model, in order of each model's first row. Only rows that name a
/// provider join: two bare ids are two models. `current` is the running row's id: its group lands it.
/// A provider's row is named without the provider ("Z.ai/GLM 5.3" is "GLM 5.3"); the menu names the
/// provider beside it.
export function groupVariants<T extends VariantModel>(models: readonly T[], current?: string): ModelGroup<T>[] {
  const groups: ModelGroup<T>[] = [];
  const byKey = new Map<string, ModelGroup<T>>();
  for (const model of models) {
    const { provider, key, name, tag } = providerOf(model);
    const offer = { model, provider: provider ?? "" };
    const group = provider ? byKey.get(key) : undefined;
    if (group) {
      group.offers.push(offer);
      if (model.id === current) group.model = model;
      group.tag ??= tag;
      continue;
    }
    const next: ModelGroup<T> = {
      model,
      name: provider ? name : model.name,
      ...(tag ? { tag } : {}),
      offers: [offer],
    };
    groups.push(next);
    if (provider) byKey.set(key, next);
  }
  return groups;
}
