// Refreshes the bundled model catalog: web/data/model-catalog/snapshot.json (what
// /api/models/v1 serves before its first live fetch and during an outage) and the
// identical copy acpmux bundles as its offline and first-run catalog
// (cmux-tui/crates/acpmux/catalog/models-v1.json). tests/model-catalog.test.ts fails
// when the two drift apart.
//
//   bun tools/refresh-model-catalog-snapshot.ts            # fetch models.dev
//   bun tools/refresh-model-catalog-snapshot.ts --feed api.json [--generated-at ISO]
//   bun tools/refresh-model-catalog-snapshot.ts --current-families-only
//
// Run it after editing services/model-catalog/overrides.ts.

import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

import { projectCatalog } from "../services/model-catalog/project";
import { withCurrentFamilyFallbacks } from "../services/model-catalog/currentFamilies";
import { validateCatalog } from "../services/model-catalog/schema";
import { fetchFeed } from "../services/model-catalog/upstream";
import { BUNDLED_CATALOG_PATH, SNAPSHOT_PATH } from "./model-catalog-paths";

function argument(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

async function main(): Promise<void> {
  const from = argument("--feed");
  const previous = process.argv.includes("--current-families-only")
    ? validateCatalog(JSON.parse(await readFile(SNAPSHOT_PATH, "utf8")))
    : projectCatalog(
        from ? JSON.parse(await readFile(from, "utf8")) : await fetchFeed(),
        new Date(argument("--generated-at") ?? Date.now()),
        undefined,
        "snapshot",
      );
  const catalog = validateCatalog(
    withCurrentFamilyFallbacks(previous, new Date(argument("--generated-at") ?? Date.now())),
  );
  const body = `${JSON.stringify(catalog)}\n`;
  for (const path of [SNAPSHOT_PATH, BUNDLED_CATALOG_PATH]) {
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, body);
  }
  const counts = catalog.harnesses
    .map((harness) => `${harness.id}:${harness.models.length}`)
    .join(" ");
  console.log(
    `wrote ${counts}; ${Object.keys(catalog.models).length} models, ${Buffer.byteLength(body)} bytes`,
  );
}

await main();
