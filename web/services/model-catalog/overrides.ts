import type { EffortValue, HarnessModel } from "./types";

// cmux's layer over the public model feed: which harnesses the composer lists, which feed models
// each one offers, and what the feed does not say (display names, harness ids, fast mode, effort).
// Edit this file to change the catalog; GET /api/models/catalog applies it to every feed refresh.

/** Feed models a catalog harness lists. `include`/`exclude` are id prefixes or `*suffix` globs. */
export interface HarnessSource {
  provider: string;
  include?: string[];
  exclude?: string[];
}

/** Per-model fields cmux sets over the feed; `hidden` removes the model from the harness. */
export type ModelOverride = Partial<Omit<HarnessModel, "id" | "ref">> & { hidden?: boolean };

export interface HarnessOverride {
  id: string;
  name: string;
  brand: string;
  families: string[];
  modelSource: "catalog" | "probe";
  /** Feed models for a "catalog" harness. */
  sources?: HarnessSource[];
  /** The harness id of a feed model: its feed id ("claude-opus-4-8"). Always the feed id today. */
  defaultModel?: string;
  /** Effort a model starts on when it offers it. */
  defaultEffort?: EffortValue;
  /** Effort values the harness never takes (the feed lists API values the harness lacks). */
  dropEfforts?: EffortValue[];
  /** Text removed from the start of a model name for the composer chip ("Claude "). */
  shortNamePrefix?: string;
  /** Group labels by feed family id ("claude-opus" -> "Opus"); unknown families keep the feed id. */
  familyNames?: Record<string, string>;
  /** Group by the model's provider (multi-provider harnesses) instead of its family. */
  groupByProvider?: boolean;
  /** Short alias ids the harness accepts for the newest model of a family ("opus"). */
  familyAliases?: Record<string, string>;
  models?: Record<string, ModelOverride>;
}

/** Feed providers whose models are described in `models` (catalog metadata for probed ids). */
export const METADATA_PROVIDERS = [
  "anthropic",
  "openai",
  "google",
  "xai",
  "deepseek",
  "mistral",
  "moonshotai",
  "zai",
  "alibaba",
  "opencode",
  "opencode-go",
  "vercel",
] as const;

/** Dated snapshot ids ("claude-opus-4-5-20251101") duplicate their undated alias. */
const DATED = "*-20[0-9][0-9][0-9][0-9][0-9][0-9]";

export const HARNESS_OVERRIDES: HarnessOverride[] = [
  {
    id: "claude",
    name: "Claude Code",
    brand: "claude",
    families: ["claude"],
    modelSource: "catalog",
    sources: [{ provider: "anthropic", include: ["claude-"], exclude: [DATED, "claude-3"] }],
    defaultModel: "claude-sonnet-5",
    shortNamePrefix: "Claude ",
    familyNames: { "claude-fable": "Fable", "claude-opus": "Opus", "claude-sonnet": "Sonnet", "claude-haiku": "Haiku" },
    familyAliases: { "claude-opus": "opus", "claude-sonnet": "sonnet", "claude-haiku": "haiku" },
  },
  {
    id: "codex",
    name: "Codex",
    brand: "openai",
    families: ["codex"],
    modelSource: "catalog",
    sources: [{ provider: "openai", include: ["gpt-5", "gpt-6"], exclude: ["*-chat-latest", "*-nano", "gpt-5-mini", "*-pro"] }],
    defaultModel: "gpt-5.5",
    defaultEffort: "medium",
    dropEfforts: ["none"],
    familyNames: {
      gpt: "GPT",
      "gpt-mini": "GPT mini",
      "gpt-codex": "GPT Codex",
      "gpt-sol": "Sol",
      "gpt-luna": "Luna",
      "gpt-terra": "Terra",
      "gpt-astra": "Astra",
    },
  },
  { id: "opencode", name: "OpenCode", brand: "opencode", families: ["opencode"], modelSource: "probe" },
  { id: "pi", name: "Pi", brand: "pi", families: ["pi"], modelSource: "probe" },
  {
    id: "vercel-ai-gateway",
    name: "Vercel AI Gateway",
    brand: "vercel",
    families: ["vercel-ai-gateway"],
    modelSource: "catalog",
    sources: [
      {
        provider: "vercel",
        include: ["anthropic/claude-", "openai/gpt-5", "openai/gpt-6", "google/gemini-3", "xai/grok-", "deepseek/", "moonshotai/", "zai/", "alibaba/qwen3-coder"],
        exclude: [DATED, "*-chat-latest", "*-nano"],
      },
    ],
    defaultModel: "anthropic/claude-sonnet-5",
    groupByProvider: true,
  },
];
