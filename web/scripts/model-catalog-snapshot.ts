#!/usr/bin/env bun
// Regenerates the bundled model catalog snapshot (the offline fallback) from the live feed:
//   bun scripts/model-catalog-snapshot.ts [--feed <saved api.json>]
// Writes web/data/model-catalog-snapshot.json and the agent pane copy (webviews generated/).
import { readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { projectCatalog } from "../services/model-catalog/project";
import { MODEL_FEED_URL } from "../services/model-catalog/route";

const webRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const targets = [
  resolve(webRoot, "data/model-catalog-snapshot.json"),
  resolve(webRoot, "../webviews/src/agent-session/acpmux/generated/model-catalog-snapshot.json"),
];

const feedFlag = process.argv.indexOf("--feed");
const feed: unknown =
  feedFlag > 0
    ? JSON.parse(await readFile(process.argv[feedFlag + 1]!, "utf8"))
    : await (await fetch(MODEL_FEED_URL, { headers: { accept: "application/json" } })).json();

const catalog = projectCatalog(feed, new Date(), undefined, "snapshot");
const body = `${JSON.stringify(catalog)}\n`;
for (const target of targets) await writeFile(target, body);
console.log(`wrote ${catalog.harnesses.map((h) => `${h.id}:${h.models.length}`).join(" ")}; ${Object.keys(catalog.models).length} models, ${body.length} bytes`);
