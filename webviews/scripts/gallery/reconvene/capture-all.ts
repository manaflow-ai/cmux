// Captures every reconvene item's stills in one run: merges scripts/gallery/reconvene/*.json (one
// capture-states spec per item, src/agent-session/acpmux/reconvene) and hands the merged spec to
// capture-states.mjs. Usage, on the fleet (never on an agent host):
//   cmux-ci test --artifact /tmp/reconvene -- bash -c 'cd webviews && bun scripts/gallery/reconvene/capture-all.ts "$FAST_CHECKS_OUT" [item ...]'
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const [out = process.env.FAST_CHECKS_OUT ?? "reconvene-captures", ...only] = process.argv.slice(2);
const dir = import.meta.dir;
const specs = readdirSync(dir)
  .filter((name) => name.endsWith(".json"))
  .filter((name) => only.length === 0 || only.includes(name.replace(/\.json$/, "")))
  .map((name) => JSON.parse(readFileSync(join(dir, name), "utf8")) as { envs?: unknown; shots: unknown[] });
const merged = {
  envs: [
    ["light", "none"],
    ["dark", "none"],
  ],
  shots: specs.flatMap((spec) => spec.shots),
};
const path = join(out, "reconvene-spec.json");
spawnSync("mkdir", ["-p", out]);
writeFileSync(path, JSON.stringify(merged, null, 2));
const run = spawnSync("bun", [join(dir, "../capture-states.mjs"), path, out], { stdio: "inherit" });
process.exit(run.status ?? 1);
