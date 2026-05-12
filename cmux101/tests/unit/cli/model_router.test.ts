import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { resolveModel, BUILTIN_ALIASES } from "@/cli/model_router";
import { expandEnv } from "@/cli/config";
import type { Config } from "@/core/types";

// ---------------------------------------------------------------------------
// Minimal config factory
// ---------------------------------------------------------------------------

function makeConfig(aliases?: Record<string, string>): Config {
  return {
    defaultProvider: "anthropic",
    defaultModel: "claude-opus-4-7",
    providers: {},
    aliases,
  };
}

// ---------------------------------------------------------------------------
// Built-in alias lookup
// ---------------------------------------------------------------------------

describe("resolveModel — built-in alias lookup", () => {
  test("opus resolves to anthropic/claude-opus-4-7", () => {
    const r = resolveModel("opus", makeConfig());
    expect(r).toEqual({ providerId: "anthropic", modelId: "claude-opus-4-7" });
  });

  test("sonnet resolves to anthropic/claude-sonnet-4-5", () => {
    const r = resolveModel("sonnet", makeConfig());
    expect(r).toEqual({ providerId: "anthropic", modelId: "claude-sonnet-4-5" });
  });

  test("haiku resolves to anthropic/claude-haiku-4-5", () => {
    const r = resolveModel("haiku", makeConfig());
    expect(r).toEqual({ providerId: "anthropic", modelId: "claude-haiku-4-5" });
  });

  test("gpt4o resolves to openai/gpt-4o", () => {
    const r = resolveModel("gpt4o", makeConfig());
    expect(r).toEqual({ providerId: "openai", modelId: "gpt-4o" });
  });

  test("flash resolves to gemini/gemini-2.5-flash", () => {
    const r = resolveModel("flash", makeConfig());
    expect(r).toEqual({ providerId: "gemini", modelId: "gemini-2.5-flash" });
  });

  test("pro resolves to gemini/gemini-2.5-pro", () => {
    const r = resolveModel("pro", makeConfig());
    expect(r).toEqual({ providerId: "gemini", modelId: "gemini-2.5-pro" });
  });

  test("gpt5 resolves to openai/gpt-5", () => {
    const r = resolveModel("gpt5", makeConfig());
    expect(r).toEqual({ providerId: "openai", modelId: "gpt-5" });
  });
});

// ---------------------------------------------------------------------------
// Alias chaining
// ---------------------------------------------------------------------------

describe("resolveModel — alias chains", () => {
  test("chain of 2: fast -> sonnet -> anthropic/claude-sonnet-4-5", () => {
    const r = resolveModel("fast", makeConfig({ fast: "sonnet" }));
    expect(r).toEqual({ providerId: "anthropic", modelId: "claude-sonnet-4-5" });
  });

  test("chain of 3: a -> b -> sonnet -> anthropic/claude-sonnet-4-5", () => {
    const r = resolveModel("a", makeConfig({ a: "b", b: "sonnet" }));
    expect(r).toEqual({ providerId: "anthropic", modelId: "claude-sonnet-4-5" });
  });

  test("non-cyclic chain terminates and falls through to routing", () => {
    // After 5 hops, whatever remains is routed normally.
    const r = resolveModel("alias1", makeConfig({
      alias1: "alias2",
      alias2: "alias3",
      alias3: "alias4",
      alias4: "alias5",
      alias5: "claude-haiku-4-5", // prefix route → anthropic
    }));
    expect(r.providerId).toBe("anthropic");
    expect(r.modelId).toBe("claude-haiku-4-5");
  });
});

// ---------------------------------------------------------------------------
// provider/model splitting
// ---------------------------------------------------------------------------

describe("resolveModel — provider/model split", () => {
  test("anthropic/claude-sonnet-4-5", () => {
    const r = resolveModel("anthropic/claude-sonnet-4-5", makeConfig());
    expect(r).toEqual({ providerId: "anthropic", modelId: "claude-sonnet-4-5" });
  });

  test("openrouter/openai/gpt-4o-mini — only first slash splits", () => {
    const r = resolveModel("openrouter/openai/gpt-4o-mini", makeConfig());
    expect(r).toEqual({ providerId: "openrouter", modelId: "openai/gpt-4o-mini" });
  });

  test("gemini/gemini-2.5-flash", () => {
    const r = resolveModel("gemini/gemini-2.5-flash", makeConfig());
    expect(r).toEqual({ providerId: "gemini", modelId: "gemini-2.5-flash" });
  });
});

// ---------------------------------------------------------------------------
// Prefix routing
// ---------------------------------------------------------------------------

describe("resolveModel — prefix routing", () => {
  test("claude-* routes to anthropic", () => {
    const r = resolveModel("claude-3-opus", makeConfig());
    expect(r).toEqual({ providerId: "anthropic", modelId: "claude-3-opus" });
  });

  test("gpt-* routes to openai", () => {
    const r = resolveModel("gpt-4-turbo", makeConfig());
    expect(r).toEqual({ providerId: "openai", modelId: "gpt-4-turbo" });
  });

  test("o1* routes to openai", () => {
    const r = resolveModel("o1-mini", makeConfig());
    expect(r).toEqual({ providerId: "openai", modelId: "o1-mini" });
  });

  test("o3* routes to openai", () => {
    const r = resolveModel("o3-pro", makeConfig());
    expect(r).toEqual({ providerId: "openai", modelId: "o3-pro" });
  });

  test("o4* routes to openai", () => {
    const r = resolveModel("o4-mini", makeConfig());
    expect(r).toEqual({ providerId: "openai", modelId: "o4-mini" });
  });

  test("gemini-* routes to gemini", () => {
    const r = resolveModel("gemini-1.5-pro", makeConfig());
    expect(r).toEqual({ providerId: "gemini", modelId: "gemini-1.5-pro" });
  });

  test("grok-* routes to openrouter", () => {
    const r = resolveModel("grok-2", makeConfig());
    expect(r).toEqual({ providerId: "openrouter", modelId: "grok-2" });
  });

  test("llama* routes to ollama", () => {
    const r = resolveModel("llama3.1-8b", makeConfig());
    expect(r).toEqual({ providerId: "ollama", modelId: "llama3.1-8b" });
  });

  test("qwen* routes to ollama", () => {
    const r = resolveModel("qwen2.5-72b", makeConfig());
    expect(r).toEqual({ providerId: "ollama", modelId: "qwen2.5-72b" });
  });

  test("mistral* routes to ollama", () => {
    const r = resolveModel("mistral-7b", makeConfig());
    expect(r).toEqual({ providerId: "ollama", modelId: "mistral-7b" });
  });
});

// ---------------------------------------------------------------------------
// Fallback
// ---------------------------------------------------------------------------

describe("resolveModel — fallback", () => {
  test("unknown model string uses config.defaultProvider", () => {
    const config = makeConfig();
    config.defaultProvider = "openai";
    const r = resolveModel("some-unknown-model", config);
    expect(r).toEqual({ providerId: "openai", modelId: "some-unknown-model" });
  });
});

// ---------------------------------------------------------------------------
// User aliases override built-ins
// ---------------------------------------------------------------------------

describe("resolveModel — user aliases override built-ins", () => {
  test("user alias for 'sonnet' overrides the built-in", () => {
    const r = resolveModel("sonnet", makeConfig({ sonnet: "openai/gpt-4o" }));
    expect(r).toEqual({ providerId: "openai", modelId: "gpt-4o" });
  });

  test("user-defined alias resolves to provider/model", () => {
    const r = resolveModel("smart", makeConfig({ smart: "anthropic/claude-opus-4-7" }));
    expect(r).toEqual({ providerId: "anthropic", modelId: "claude-opus-4-7" });
  });

  test("user alias 'cheap' pointing to openrouter", () => {
    const r = resolveModel("cheap", makeConfig({ cheap: "openrouter/openai/gpt-4o-mini" }));
    expect(r).toEqual({ providerId: "openrouter", modelId: "openai/gpt-4o-mini" });
  });
});

// ---------------------------------------------------------------------------
// expandEnv
// ---------------------------------------------------------------------------

describe("expandEnv", () => {
  let origKey: string | undefined;

  beforeEach(() => {
    origKey = process.env.TEST_CMUX_KEY;
  });

  afterEach(() => {
    if (origKey === undefined) {
      delete process.env.TEST_CMUX_KEY;
    } else {
      process.env.TEST_CMUX_KEY = origKey;
    }
  });

  test("replaces ${VAR} with env value", () => {
    process.env.TEST_CMUX_KEY = "sk-abc123";
    expect(expandEnv("${TEST_CMUX_KEY}")).toBe("sk-abc123");
  });

  test("replaces ${VAR} embedded in a longer string", () => {
    process.env.TEST_CMUX_KEY = "mykey";
    expect(expandEnv("Bearer ${TEST_CMUX_KEY}")).toBe("Bearer mykey");
  });

  test("unset variable expands to empty string", () => {
    delete process.env.TEST_CMUX_KEY;
    expect(expandEnv("${TEST_CMUX_KEY}")).toBe("");
  });

  test("string with no placeholders is returned unchanged", () => {
    expect(expandEnv("hello world")).toBe("hello world");
  });

  test("multiple placeholders in one string", () => {
    process.env.TEST_CMUX_KEY = "A";
    expect(expandEnv("${TEST_CMUX_KEY}-${TEST_CMUX_KEY}")).toBe("A-A");
  });
});
