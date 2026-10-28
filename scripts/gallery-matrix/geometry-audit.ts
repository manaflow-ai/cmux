#!/usr/bin/env bun
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { parseManifest, runLocal } from "./runner";
import { parseConfig } from "./geometry";
import { main as lint } from "./geometry-lint";

export async function audit(args = process.argv.slice(2)): Promise<number> {
  const { values } = parseArgs({ args, options: { config: { type: "string", default: join(import.meta.dir, "geometry-baseline.json") }, "gallery-dir": { type: "string" }, "output-dir": { type: "string" }, "expected-sha": { type: "string" } } });
  if (!values["gallery-dir"] || !values["output-dir"] || !values["expected-sha"]) throw new Error("--gallery-dir, --output-dir and --expected-sha are required");
  if (process.env.CMUX_GALLERY_IN_VM !== "1") throw new Error("geometry capture runs only on fleet/CI");
  const config = JSON.parse(await readFile(values.config!, "utf8"));
  parseConfig(config);
  const cases = parseManifest(config.cases);
  const output = resolve(values["output-dir"]);
  await mkdir(output, { recursive: true });
  const manifest = join(output, "manifest.json");
  const selectors = join(output, "selectors.json");
  await writeFile(manifest, JSON.stringify(cases));
  await writeFile(selectors, JSON.stringify(config.selectors));
  process.env.CMUX_GEOMETRY_SELECTORS = selectors;
  await runLocal({ manifest, galleryDir: values["gallery-dir"], outputDir: output, threshold: 0, engines: ["chromium"], shardCount: 1, shardIndex: 0 });
  return lint(["--artifact-dir", output, "--config", values.config!, "--report-dir", join(output, "geometry-report"), "--expected-sha", values["expected-sha"]]);
}
if (import.meta.main) process.exitCode = await audit();
