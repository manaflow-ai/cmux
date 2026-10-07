// Refreshes web/data/model-catalog/models-dev-snapshot.json, the models.dev
// copy the catalog serves before the first live fetch and during an outage.
//
//   bun tools/refresh-model-catalog-snapshot.ts            # fetch models.dev
//   bun tools/refresh-model-catalog-snapshot.ts --from api.json [--fetched-at ISO]
//
// Run it after editing overrides.json so the snapshot holds every curated provider.

import { readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { buildCatalog } from "../services/model-catalog/build";
import { curatedProviderIds, validateOverrides } from "../services/model-catalog/overrides";
import { fetchUpstream, selectUpstream, type UpstreamSubset } from "../services/model-catalog/upstream";

const dataDir = resolve(dirname(fileURLToPath(import.meta.url)), "../data/model-catalog");

function argument(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

async function main(): Promise<void> {
  const overrides = validateOverrides(JSON.parse(await readFile(resolve(dataDir, "overrides.json"), "utf8")));
  const providers = curatedProviderIds(overrides);
  const from = argument("--from");
  const fetchedAt = argument("--fetched-at") ?? new Date().toISOString();
  const subset: UpstreamSubset = from
    ? selectUpstream(JSON.parse(await readFile(from, "utf8")), providers, fetchedAt)
    : await fetchUpstream(providers);
  const catalog = buildCatalog(subset, overrides);
  const body = `${JSON.stringify(subset, null, 1)}\n`;
  await writeFile(resolve(dataDir, "models-dev-snapshot.json"), body);
  const models = catalog.harnesses.reduce((sum, harness) => sum + harness.models.length, 0);
  console.log(`snapshot: ${providers.length} providers, ${Buffer.byteLength(body)} bytes; catalog: ${models} models`);
}

await main();
