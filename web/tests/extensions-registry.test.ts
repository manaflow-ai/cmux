import { afterAll, afterEach, describe, expect, mock, test } from "bun:test";
import * as Effect from "effect/Effect";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import registryJson from "../data/extensions-registry.json";
import { extensionsRegistrySchema } from "../app/api/extensions/index/mapping";

const originalSkipEnvValidation = process.env.SKIP_ENV_VALIDATION;
process.env.SKIP_ENV_VALIDATION = "1";
const originalFetch = globalThis.fetch;
const { loadExtensionsRegistry } = await import("../app/api/extensions/index/route");

const registryPath = join(
  dirname(fileURLToPath(import.meta.url)),
  "../data/extensions-registry.json",
);

afterEach(() => {
  globalThis.fetch = originalFetch;
});

afterAll(() => {
  if (originalSkipEnvValidation === undefined) {
    delete process.env.SKIP_ENV_VALIDATION;
  } else {
    process.env.SKIP_ENV_VALIDATION = originalSkipEnvValidation;
  }
});

describe("extensions registry", () => {
  test("is schema-valid, unique, sorted, and uses owner/repo names", () => {
    const raw = JSON.parse(readFileSync(registryPath, "utf8"));
    const registry = extensionsRegistrySchema.parse(raw);
    const repos = registry.extensions.map((entry) => entry.repo);
    const lowercasedRepos = repos.map((repo) => repo.toLowerCase());

    expect(new Set(lowercasedRepos).size).toBe(repos.length);
    expect(repos).toEqual([...repos].sort((left, right) => left.localeCompare(right)));
    for (const repo of repos) {
      expect(repo).toMatch(/^[A-Za-z0-9-]+\/[A-Za-z0-9._-]+$/);
    }
  });

  test("loads the remote awesome-cmux registry when it is valid", async () => {
    const remoteRegistry = {
      extensions: [
        { repo: "remote/alpha", addedAt: "2026-07-01" },
        { repo: "remote/beta", addedAt: "2026-07-02" },
      ],
    };
    const fetchMock = mock(async () => Response.json(remoteRegistry));
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const registry = await Effect.runPromise(loadExtensionsRegistry());

    expect(registry).toEqual(remoteRegistry);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  test("falls back to the bundled seed when the remote registry is schema-invalid", async () => {
    const fetchMock = mock(async () =>
      Response.json({
        extensions: [{ repo: "remote/missing-date" }],
      }),
    );
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const registry = await Effect.runPromise(loadExtensionsRegistry());

    expect(registry).toEqual(extensionsRegistrySchema.parse(registryJson));
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  test("falls back to the bundled seed when the remote registry fetch fails", async () => {
    const fetchMock = mock(async () => {
      throw new Error("network unavailable");
    });
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const registry = await Effect.runPromise(loadExtensionsRegistry());

    expect(registry).toEqual(extensionsRegistrySchema.parse(registryJson));
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });
});
