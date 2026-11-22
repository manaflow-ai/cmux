#!/usr/bin/env node
// Writes wrangler.generated.json: wrangler.jsonc with the deploy target's
// Hyperdrive binding filled in from its resolved id, so no Hyperdrive id is
// committed. For preview, an optional third argument names the lane, and the
// Worker becomes cmux-vm-preview-<lane> so lanes do not overwrite each other.
// Usage: node scripts/wrangler-config.mjs <preview|staging|production> <hyperdrive-id> [lane]
import { readFileSync, writeFileSync } from "node:fs";

const [target, hyperdriveId, lane] = process.argv.slice(2);
if (!["preview", "staging", "production"].includes(target ?? "") || !/^[0-9a-f]{32}$/.test(hyperdriveId ?? "")) {
  console.error("usage: wrangler-config.mjs <preview|staging|production> <32-hex hyperdrive id>");
  process.exit(2);
}

// Removes line comments and block comments outside strings.
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
if (target === "preview" && lane) {
  if (!/^[a-z0-9][a-z0-9-]{0,30}$/.test(lane)) {
    console.error("lane must be 1-31 lowercase letters, digits or '-'");
    process.exit(2);
  }
  env.name = `cmux-vm-preview-${lane}`;
}
// Custom domains are attached by scripts/custom-domains.sh through the account
// Workers domains API, not by wrangler: with routes in its config, wrangler
// also reads the zone's route list, which needs a zone-scoped permission the
// deploy token does not have (staging deploy 2026-10-07: "No access").
const customDomains = (env.routes ?? []).map((route) => {
  if (typeof route !== "object" || route.custom_domain !== true || typeof route.pattern !== "string") {
    console.error("only custom-domain routes are supported; add other routes deliberately");
    process.exit(1);
  }
  return route.pattern;
});
delete env.routes;
delete config.$schema;
writeFileSync(new URL("wrangler.generated.json", root), `${JSON.stringify(config, null, 2)}\n`);
writeFileSync(new URL("custom-domains.generated.txt", root), customDomains.map((host) => `${host}\n`).join(""));
console.log(`wrote wrangler.generated.json for ${target} (Worker ${env.name})`);
