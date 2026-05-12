/**
 * Unit tests for ProviderRegistry and createDefaultRegistry.
 */

import { test, expect, describe } from "bun:test";
import { ProviderRegistry, createDefaultRegistry } from "../../../src/providers/index.js";
import type { Provider, ProviderFactory, ModelInfo, StreamEvent } from "../../../src/core/types.js";

// ---------------------------------------------------------------------------
// Fake fixtures
// ---------------------------------------------------------------------------

function makeFakeProvider(id: string): Provider {
  return {
    id,
    displayName: `Fake ${id}`,
    async listModels(): Promise<ModelInfo[]> {
      return [];
    },
    async *stream(): AsyncIterable<StreamEvent> {
      // no-op
    },
  };
}

function makeFakeFactory(id: string, envKey: string): ProviderFactory {
  return {
    id,
    fromEnv(env: NodeJS.ProcessEnv): Provider | null {
      if (env[envKey]) return makeFakeProvider(id);
      return null;
    },
    fromConfig(_config: Record<string, unknown>): Provider {
      return makeFakeProvider(id);
    },
  };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("ProviderRegistry", () => {
  test("register and list a factory's instance after loadFromEnv", async () => {
    const registry = new ProviderRegistry();
    registry.register(makeFakeFactory("alpha", "ALPHA_API_KEY"));

    const loaded = await registry.loadFromEnv({ ALPHA_API_KEY: "secret" });

    expect(loaded).toHaveLength(1);
    expect(loaded[0].id).toBe("alpha");
    expect(registry.list()).toHaveLength(1);
    expect(registry.list()[0].id).toBe("alpha");
  });

  test("get returns the instance produced by loadFromEnv", async () => {
    const registry = new ProviderRegistry();
    registry.register(makeFakeFactory("beta", "BETA_KEY"));

    await registry.loadFromEnv({ BETA_KEY: "x" });

    const instance = registry.get("beta");
    expect(instance).toBeDefined();
    expect(instance!.id).toBe("beta");
  });

  test("get returns undefined for an id that was never loaded", () => {
    const registry = new ProviderRegistry();
    registry.register(makeFakeFactory("gamma", "GAMMA_KEY"));
    expect(registry.get("gamma")).toBeUndefined();
  });

  test("loadFromEnv only registers factories that return non-null", async () => {
    const registry = new ProviderRegistry();
    registry.register(makeFakeFactory("present", "PRESENT_KEY"));
    registry.register(makeFakeFactory("absent", "ABSENT_KEY"));

    const loaded = await registry.loadFromEnv({ PRESENT_KEY: "yes" }); // ABSENT_KEY not set

    expect(loaded).toHaveLength(1);
    expect(loaded[0].id).toBe("present");
    expect(registry.get("absent")).toBeUndefined();
    expect(registry.list()).toHaveLength(1);
  });

  test("loadFromConfig instantiates providers from config blob", async () => {
    const registry = new ProviderRegistry();
    registry.register(makeFakeFactory("delta", "DELTA_KEY"));

    const loaded = await registry.loadFromConfig({
      defaultProvider: "delta",
      defaultModel: "delta-v1",
      providers: { delta: { apiKey: "cfg-key" } },
    });

    expect(loaded).toHaveLength(1);
    expect(loaded[0].id).toBe("delta");
    expect(registry.get("delta")).toBeDefined();
  });

  test("loadFromConfig skips providers with no matching factory", async () => {
    const registry = new ProviderRegistry();
    // No factory registered

    const loaded = await registry.loadFromConfig({
      defaultProvider: "unknown",
      defaultModel: "x",
      providers: { unknown: { apiKey: "key" } },
    });

    expect(loaded).toHaveLength(0);
  });

  test("register replaces existing factory", async () => {
    const registry = new ProviderRegistry();
    const factory1 = makeFakeFactory("zeta", "ZETA_KEY");
    const factory2: ProviderFactory = {
      id: "zeta",
      fromEnv(env) {
        if (env["ZETA_KEY"]) {
          return { ...makeFakeProvider("zeta"), displayName: "Zeta v2" };
        }
        return null;
      },
      fromConfig(_cfg) {
        return makeFakeProvider("zeta");
      },
    };

    registry.register(factory1);
    registry.register(factory2);

    const loaded = await registry.loadFromEnv({ ZETA_KEY: "val" });
    expect(loaded[0].displayName).toBe("Zeta v2");
  });
});

describe("createDefaultRegistry", () => {
  test("does not crash when no env vars are set", async () => {
    const registry = await createDefaultRegistry();
    // Should not throw
    expect(registry).toBeDefined();
    const loaded = await registry.loadFromEnv({});
    // No providers should load without env vars
    expect(Array.isArray(loaded)).toBe(true);
  });

  test("returns a ProviderRegistry instance", async () => {
    const registry = await createDefaultRegistry();
    expect(registry).toBeInstanceOf(ProviderRegistry);
  });

  test("list() returns empty array before any loadFromEnv call", async () => {
    const registry = await createDefaultRegistry();
    expect(registry.list()).toEqual([]);
  });
});
