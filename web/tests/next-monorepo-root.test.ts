import { describe, expect, test } from "bun:test";
import path from "node:path";
import { fileURLToPath } from "node:url";

import nextConfig from "../next.config";
import { MANAGED_IROH_RELAY_CATALOG } from "../../workers/presence/src/generated/managedRelayCatalog";
import {
  MANAGED_RELAY_CATALOG_SEQUENCE,
  MANAGED_RELAY_URLS,
} from "../services/iroh/publicationPolicy";

describe("Next monorepo module boundary", () => {
  test("contains the single generated relay catalog consumed at runtime", () => {
    const webRoot = path.dirname(fileURLToPath(new URL("../next.config.ts", import.meta.url)));
    const repositoryRoot = path.resolve(webRoot, "..");
    const catalogPath = fileURLToPath(
      new URL("../../workers/presence/src/generated/managedRelayCatalog.ts", import.meta.url),
    );
    const relativeCatalogPath = path.relative(repositoryRoot, catalogPath);

    expect(nextConfig.turbopack?.root).toBe(repositoryRoot);
    expect(relativeCatalogPath.startsWith(`..${path.sep}`)).toBeFalse();
    expect(MANAGED_RELAY_CATALOG_SEQUENCE).toBe(MANAGED_IROH_RELAY_CATALOG.sequence);
    expect(MANAGED_RELAY_URLS).toEqual(
      MANAGED_IROH_RELAY_CATALOG.relays.map((relay) => relay.url),
    );
  });
});
