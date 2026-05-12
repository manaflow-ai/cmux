/**
 * Provider registry for cmux101.
 *
 * Maintains a set of ProviderFactory registrations and the Provider instances
 * produced from them. createDefaultRegistry() is ASYNC — always `await` it.
 */

import type { Config, Provider, ProviderFactory } from "../core/types.js";

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

async function tryImport<T>(path: string): Promise<T | null> {
  try {
    return await import(path);
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// ProviderRegistry
// ---------------------------------------------------------------------------

export class ProviderRegistry {
  private readonly factories = new Map<string, ProviderFactory>();
  private readonly instances = new Map<string, Provider>();

  /** Register a provider factory. Replaces any existing factory with the same id. */
  register(factory: ProviderFactory): void {
    this.factories.set(factory.id, factory);
  }

  /**
   * Get a provider instance by id.
   * Only returns a provider if one was previously produced via loadFromEnv or
   * loadFromConfig.
   */
  get(id: string): Provider | undefined {
    return this.instances.get(id);
  }

  /** List all instantiated providers. */
  list(): Provider[] {
    return Array.from(this.instances.values());
  }

  /**
   * For each registered factory, attempt to construct a provider from the
   * environment. Non-null results are stored and returned.
   */
  async loadFromEnv(env: NodeJS.ProcessEnv = process.env): Promise<Provider[]> {
    const loaded: Provider[] = [];
    for (const factory of this.factories.values()) {
      try {
        const provider = factory.fromEnv(env);
        if (provider !== null) {
          this.instances.set(provider.id, provider);
          loaded.push(provider);
        }
      } catch {
        // Ignore per-factory errors so other providers still load
      }
    }
    return loaded;
  }

  /**
   * For each entry in config.providers, find the matching factory and construct
   * a provider from the config blob. Stores and returns all successfully created
   * providers.
   */
  async loadFromConfig(config: Config): Promise<Provider[]> {
    const loaded: Provider[] = [];
    for (const [id, providerConfig] of Object.entries(config.providers)) {
      const factory = this.factories.get(id);
      if (!factory) continue;
      try {
        const provider = factory.fromConfig(providerConfig);
        this.instances.set(provider.id, provider);
        loaded.push(provider);
      } catch {
        // Ignore per-factory errors
      }
    }
    return loaded;
  }
}

// ---------------------------------------------------------------------------
// createDefaultRegistry — ASYNC
// ---------------------------------------------------------------------------

/**
 * Create a ProviderRegistry pre-populated with all built-in provider factories.
 *
 * Uses dynamic imports so missing provider modules (e.g. when optional deps are
 * absent) don't crash registration.
 *
 * @example
 *   const registry = await createDefaultRegistry();
 *   const providers = await registry.loadFromEnv();
 */
export async function createDefaultRegistry(): Promise<ProviderRegistry> {
  const registry = new ProviderRegistry();

  type FactoryModule = Record<string, unknown>;

  const builtinPaths = [
    "./anthropic.js",
    "./openai.js",
    "./gemini.js",
    "./openrouter.js",
    "./bedrock.js",
    "./vertex.js",
    "./local.js",
  ];

  const imports = await Promise.all(
    builtinPaths.map((p) => tryImport<FactoryModule>(p)),
  );

  for (const mod of imports) {
    if (!mod) continue;
    for (const value of Object.values(mod)) {
      if (
        value !== null &&
        typeof value === "object" &&
        "id" in value &&
        "fromEnv" in value &&
        "fromConfig" in value
      ) {
        registry.register(value as ProviderFactory);
      }
    }
  }

  return registry;
}
