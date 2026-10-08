import type { EffortValue, HarnessModel } from "./types";

// cmux's layer over the public model feed: which harnesses the composer lists, which feed models
// each one offers, and what the feed does not say (display names, harness ids, fast mode, effort).
// Edit this file to change the catalog; GET /api/models/v1 applies it to every feed refresh. Then run
// bun tools/refresh-model-catalog-snapshot.ts so the bundled copies follow.

/** Feed models a catalog harness lists. `include`/`exclude` are id prefixes or `*suffix` globs.
 *  A model the feed marks as having no tool calling is never listed (an agent needs tools). */
export interface HarnessSource {
  provider: string;
  include?: string[];
  exclude?: string[];
  /** Feed models released before this date ("2026-04-01") are left out (old generations). */
  minReleaseDate?: string;
}

/** Per-model fields cmux sets over the feed; `hidden` removes the model from the harness. */
export type ModelOverride = Partial<Omit<HarnessModel, "id" | "ref">> & { hidden?: boolean };

export interface HarnessOverride {
  id: string;
  name: string;
  brand: string;
  families: string[];
  modelSource: "catalog" | "probe";
  /** Install and sign-in docs (https, on schema.ts DOCS_URL_HOSTS). */
  docsUrl?: string;
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
  /** Group labels by feed family id ("claude-opus" -> "Opus"), in display order; unknown families
   *  keep the feed id and follow, newest first. */
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

/** Gateway ids that are a mode, a media model or a variant of a listed model, not a chat model. */
const GATEWAY_VARIANTS = [
  "*-fast", "*-highspeed", "*-flashx", "*-exp", "*-pro", "*-nano", "*-chat-latest",
  "*-tts", "*-image", "*-image-preview", "*-live", "*-live-extended-thinking", "*-transcribe",
];

export const HARNESS_OVERRIDES: HarnessOverride[] = [
  {
    id: "claude", docsUrl: "https://docs.claude.com/en/docs/claude-code/setup",
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
    id: "codex", docsUrl: "https://developers.openai.com/codex/cli",
    name: "Codex",
    brand: "openai",
    families: ["codex"],
    modelSource: "catalog",
    sources: [
      { provider: "openai", include: ["gpt-"], exclude: ["gpt-oss", "gpt-realtime", "gpt-image", "gpt-audio", "*-latest", "*-nano", "*-pro"], minReleaseDate: "2026-04-01" },
    ],
    defaultModel: "gpt-5.5",
    defaultEffort: "medium",
    dropEfforts: ["none"],
    familyNames: {
      "gpt-sol": "Sol",
      "gpt-astra": "Astra",
      "gpt-luna": "Luna",
      "gpt-terra": "Terra",
      gpt: "GPT",
      "gpt-codex": "GPT Codex",
      "gpt-mini": "GPT mini",
    },
  },
  { id: "opencode", docsUrl: "https://opencode.ai/docs", name: "OpenCode", brand: "opencode", families: ["opencode"], modelSource: "probe" },
  { id: "pi", docsUrl: "https://github.com/earendil-works/pi", name: "Pi", brand: "pi", families: ["pi"], modelSource: "probe" },
  {
    id: "vercel-ai-gateway", docsUrl: "https://vercel.com/docs/ai-gateway",
    name: "Vercel AI Gateway",
    brand: "vercel",
    families: ["vercel-ai-gateway"],
    modelSource: "catalog",
    sources: [
      {
        provider: "vercel",
        include: ["anthropic/claude-", "openai/gpt-5", "openai/gpt-6", "google/gemini-3", "xai/grok-", "deepseek/", "moonshotai/", "zai/", "alibaba/qwen3-coder"],
        exclude: [DATED, "*-[0-9][0-9][0-9][0-9]", ...GATEWAY_VARIANTS],
        minReleaseDate: "2026-01-01",
      },
    ],
    defaultModel: "anthropic/claude-sonnet-5",
    groupByProvider: true,
  },
];
