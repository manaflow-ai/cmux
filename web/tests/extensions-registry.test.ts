import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { extensionsRegistrySchema } from "../app/api/extensions/index/mapping";

const registryPath = join(
  dirname(fileURLToPath(import.meta.url)),
  "../data/extensions-registry.json",
);

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
});
