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
/// without any provider path, which rows of one model share), `vendor` (the path segment before the
/// key when the id has one, "deepseek" in "openrouter/deepseek/deepseek-v4-pro") and the name
/// without a provider prefix ("OpenRouter/DeepSeek V4 Pro" is "DeepSeek V4 Pro") or bracketed tag.
export function providerOf(model: VariantModel): {
  provider?: string;
  key: string;
  vendor?: string;
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
  const vendor = parts.length > 2 ? parts.at(-2)!.toLowerCase() : undefined;
  return {
    ...(provider ? { provider } : {}),
    key: (parts.at(-1) ?? model.id).toLowerCase(),
    ...(vendor ? { vendor } : {}),
    name: bare.replace(BRACKET_TAG, ""),
    ...(tag ? { tag } : {}),
  };
}

/// `models` as one row per model, in order of each model's first row. Only rows that name a
/// provider join: two bare ids are two models. `current` is the running row's id: its group lands it.
/// A provider's row is named without the provider ("Z.ai/GLM 5.3" is "GLM 5.3"); the menu names the
/// provider beside it. Rows whose ids name different vendors ("openrouter/qwen/coder-3",
/// "together/mistral/coder-3") are different models even when their last segments match. A row
/// that names no vendor ("qwen/coder-3") joins the model of the vendor its provider is, else the
/// only model with its last segment; when that is ambiguous it is its own model.
export function groupVariants<T extends VariantModel>(models: readonly T[], current?: string): ModelGroup<T>[] {
  type Group = { key: string; vendor?: string; rows: number[] };
  const read = models.map((model) => providerOf(model));
  const groups: Group[] = [];
  const byKey = new Map<string, Group[]>();
  const add = (index: number, vendor?: string) => {
    const group: Group = { key: read[index]!.key, ...(vendor ? { vendor } : {}), rows: [index] };
    groups.push(group);
    byKey.set(group.key, [...(byKey.get(group.key) ?? []), group]);
  };
  // Rows that name their vendor first, so a row that does not can find its vendor's model.
  read.forEach((row, index) => {
    if (!row.provider) return add(index);
    if (!row.vendor) return;
    const group = byKey.get(row.key)?.find((candidate) => candidate.vendor === row.vendor);
    if (group) group.rows.push(index);
    else add(index, row.vendor);
  });
  read.forEach((row, index) => {
    if (!row.provider || row.vendor) return;
    const own = models[index]!.id.split("/")[0]!.toLowerCase();
    const candidates = byKey.get(row.key) ?? [];
    const group =
      candidates.find((candidate) => candidate.vendor === own) ??
      (candidates.length === 1 ? candidates[0] : candidates.find((candidate) => !candidate.vendor));
    if (group && read[group.rows[0]!]!.provider) group.rows.push(index);
    else add(index);
  });
  return groups
    .map((group) => group.rows.sort((a, b) => a - b))
    .sort((a, b) => a[0]! - b[0]!)
    .map((rows): ModelGroup<T> => {
      const first = read[rows[0]!]!;
      const tag = rows.map((index) => read[index]!.tag).find(Boolean);
      const running = rows.find((index) => models[index]!.id === current);
      return {
        model: models[running ?? rows[0]!]!,
        name: first.provider ? first.name : models[rows[0]!]!.name,
        ...(tag ? { tag } : {}),
        offers: rows.map((index) => ({ model: models[index]!, provider: read[index]!.provider ?? "" })),
      };
    });
}
