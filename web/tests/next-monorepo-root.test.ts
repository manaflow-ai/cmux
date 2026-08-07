import { describe, expect, test } from "bun:test";
import path from "node:path";
import { fileURLToPath } from "node:url";

import nextConfig from "../next.config";
import { MANAGED_IROH_RELAY_CATALOG } from "../../workers/presence/src/generated/managedRelayCatalog";
import { MANAGED_IROH_RELAY_CATALOG as WEB_MANAGED_IROH_RELAY_CATALOG } from "../services/relay/generated/managedRelayCatalog";
import {
  MANAGED_RELAY_CATALOG_SEQUENCE,
  MANAGED_RELAY_URLS,
} from "../services/iroh/publicationPolicy";

describe("Next monorepo module boundary", () => {
  test("keeps runtime imports inside web while generated consumers remain identical", () => {
    const webRoot = path.dirname(fileURLToPath(new URL("../next.config.ts", import.meta.url)));
    const webCatalogPath = fileURLToPath(
      new URL("../services/relay/generated/managedRelayCatalog.ts", import.meta.url),
    );
    const relativeCatalogPath = path.relative(webRoot, webCatalogPath);

    expect(nextConfig.turbopack?.root).toBe(webRoot);
    expect(relativeCatalogPath.startsWith(`..${path.sep}`)).toBeFalse();
    expect(WEB_MANAGED_IROH_RELAY_CATALOG).toEqual(MANAGED_IROH_RELAY_CATALOG);
    expect(MANAGED_RELAY_CATALOG_SEQUENCE).toBe(MANAGED_IROH_RELAY_CATALOG.sequence);
    expect(MANAGED_RELAY_URLS).toEqual(
      MANAGED_IROH_RELAY_CATALOG.relays.map((relay) => relay.url),
    );
  });
});
