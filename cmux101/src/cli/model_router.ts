/**
 * Model resolution for cmux101.
 *
 * Resolves a raw model string (from --model or config) into a
 * { providerId, modelId } pair by:
 *   1. Expanding user/built-in aliases (with chaining, up to 5 hops).
 *   2. Splitting on the first "/" (e.g. "anthropic/claude-sonnet-4-5").
 *   3. Applying prefix-based routing for well-known model families.
 *   4. Falling back to config.defaultProvider.
 *
 * Built-in aliases live here so they're always present even without a
 * config file. User aliases in config.aliases override built-ins.
 */

import type { Config } from "@/core/types";

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

export interface ResolvedModel {
  providerId: string;
  modelId: string;
}

// ---------------------------------------------------------------------------
// Built-in alias table
// ---------------------------------------------------------------------------

/**
 * These are always available. User config aliases override them if a key
 * collides.
 */
export const BUILTIN_ALIASES: Record<string, string> = {
  opus:        "anthropic/claude-opus-4-7",
  sonnet:      "anthropic/claude-sonnet-4-5",
  haiku:       "anthropic/claude-haiku-4-5",
  gpt5:        "openai/gpt-5",
  gpt4o:       "openai/gpt-4o",
  flash:       "gemini/gemini-2.5-flash",
  pro:         "gemini/gemini-2.5-pro",
  grok:        "xai/grok-3",
  "grok-mini": "xai/grok-3-mini",
  qwen:        "dashscope/qwen-plus",
  "qwen-max":  "dashscope/qwen-max",
  "qwen-coder": "dashscope/qwen3-coder",
};

// ---------------------------------------------------------------------------
// Prefix routing table
// ---------------------------------------------------------------------------

function routeByPrefix(input: string): string | null {
  // claude-*, opus, sonnet, haiku → anthropic
  if (
    input.startsWith("claude-") ||
    input === "opus" ||
    input === "sonnet" ||
    input === "haiku"
  ) {
    return "anthropic";
  }

  // gpt-*, o1*, o3*, o4* → openai
  if (
    input.startsWith("gpt-") ||
    input.startsWith("o1") ||
    input.startsWith("o3") ||
    input.startsWith("o4")
  ) {
    return "openai";
  }

  // gemini-* → gemini
  if (input.startsWith("gemini-")) {
    return "gemini";
  }

  // grok-* → xai
  if (input.startsWith("grok-")) {
    return "xai";
  }

  // qwen* → dashscope (use ollama/qwen2.5 explicitly for Ollama)
  if (input.startsWith("qwen")) {
    return "dashscope";
  }

  // llama*, mistral* → ollama
  if (
    input.startsWith("llama") ||
    input.startsWith("mistral")
  ) {
    return "ollama";
  }

  return null;
}

// ---------------------------------------------------------------------------
// Main resolution function
// ---------------------------------------------------------------------------

/**
 * Resolve a raw model string to a { providerId, modelId } pair.
 *
 * Pipeline:
 *   1. Alias expansion (user aliases override built-ins; up to 5 hops).
 *   2. First-"/" split → { providerId, modelId }.
 *   3. Prefix routing for well-known model families.
 *   4. Fallback to config.defaultProvider.
 */
export function resolveModel(input: string, config: Config): ResolvedModel {
  // Merge alias tables: built-ins first, then user overrides.
  const aliases: Record<string, string> = {
    ...BUILTIN_ALIASES,
    ...(config.aliases ?? {}),
  };

  // Step 1: Alias expansion (up to 5 hops to allow chaining).
  let current = input;
  for (let i = 0; i < 5; i++) {
    const target = aliases[current];
    if (!target || target === current) break;
    current = target;
  }

  // Step 2: Split on first "/".
  const slashIdx = current.indexOf("/");
  if (slashIdx !== -1) {
    const providerId = current.slice(0, slashIdx);
    const modelId = current.slice(slashIdx + 1);
    return { providerId, modelId };
  }

  // Step 3: Prefix routing.
  const routedProvider = routeByPrefix(current);
  if (routedProvider !== null) {
    return { providerId: routedProvider, modelId: current };
  }

  // Step 4: Fallback.
  return { providerId: config.defaultProvider, modelId: current };
}
