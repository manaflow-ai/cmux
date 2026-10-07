#!/usr/bin/env node
// Writes wrangler.generated.json: wrangler.jsonc with the deploy target's
// Hyperdrive binding filled in from its resolved id, so no Hyperdrive id is
// committed. Usage: node scripts/wrangler-config.mjs <preview|staging|production> <hyperdrive-id>
import { readFileSync, writeFileSync } from "node:fs";

const [target, hyperdriveId] = process.argv.slice(2);
if (!["preview", "staging", "production"].includes(target ?? "") || !/^[0-9a-f]{32}$/.test(hyperdriveId ?? "")) {
  console.error("usage: wrangler-config.mjs <preview|staging|production> <32-hex hyperdrive id>");
  process.exit(2);
}

/** Removes // and /* */ comments outside strings. */
function stripComments(text) {
  let out = "";
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '"') {
      let j = i + 1;
      while (j < text.length && text[j] !== '"') j += text[j] === "\\" ? 2 : 1;
      out += text.slice(i, j + 1);
      i = j;
    } else if (c === "/" && text[i + 1] === "/") {
      while (i < text.length && text[i] !== "\n") i++;
      out += "\n";
    } else if (c === "/" && text[i + 1] === "*") {
      i = text.indexOf("*/", i + 2) + 1;
    } else {
      out += c;
    }
  }
  return out;
}

const root = new URL("..", import.meta.url);
const config = JSON.parse(stripComments(readFileSync(new URL("wrangler.jsonc", root), "utf8")));
const env = config.env?.[target];
if (!env) {
  console.error(`wrangler.jsonc has no env.${target}`);
  process.exit(1);
}
env.hyperdrive = [{ binding: "HYPERDRIVE", id: hyperdriveId }];
delete config.$schema;
writeFileSync(new URL("wrangler.generated.json", root), `${JSON.stringify(config, null, 2)}\n`);
console.log(`wrote wrangler.generated.json for ${target}`);
