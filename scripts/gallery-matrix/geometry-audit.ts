#!/usr/bin/env bun
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { parseManifest, runLocal } from "./runner";
import { parseConfig } from "./geometry";
import { main as lint } from "./geometry-lint";

export function captureEnvironment(env = process.env): boolean {
  return env.CMUX_GALLERY_IN_VM === "1" || env.CI === "1" || env.CI === "true";
}

export function configForCapture<T extends { revision: { sha: string; source: string } }>(config: T, expectedSha: string): T {
  return { ...config, revision: { ...config.revision, sha: expectedSha } };
}

export async function audit(args = process.argv.slice(2)): Promise<number> {
  const { values } = parseArgs({ args, options: { config: { type: "string", default: join(import.meta.dir, "geometry-baseline.json") }, "gallery-dir": { type: "string" }, "output-dir": { type: "string" }, "expected-sha": { type: "string" } } });
  if (!values["gallery-dir"] || !values["output-dir"] || !values["expected-sha"]) throw new Error("--gallery-dir, --output-dir and --expected-sha are required");
  if (!captureEnvironment()) throw new Error("geometry capture runs only on fleet/CI");
  const config = JSON.parse(await readFile(values.config!, "utf8"));
  parseConfig(config);
  // The baseline supplies rule debt and source identity; each run captures the current tip.
  // Bind that run's source SHA explicitly instead of requiring a stale baseline SHA.
  const effective = configForCapture(config, values["expected-sha"]);
  const cases = parseManifest(effective.cases);
  const output = resolve(values["output-dir"]);
  // A rerun must never lint screenshots or geometry from an earlier attempt.
  await rm(output, { recursive: true, force: true });
  await mkdir(output, { recursive: true });
  const manifest = join(output, "manifest.json");
  const selectors = join(output, "selectors.json");
  await writeFile(manifest, JSON.stringify(cases));
  await writeFile(selectors, JSON.stringify(effective.selectors));
  const effectiveConfig = join(output, "geometry-config.json");
  await writeFile(effectiveConfig, `${JSON.stringify(effective, null, 2)}\n`);
  process.env.CMUX_GEOMETRY_SELECTORS = selectors;
  await runLocal({ manifest, galleryDir: values["gallery-dir"], outputDir: output, threshold: 0, engines: ["chromium"], shardCount: 1, shardIndex: 0 });
  const results = JSON.parse(await readFile(join(output, "results.json"))) as Array<{ ready?: string }>;
  const captureFailed = results.some((result) => result.ready !== "1");
  // runLocal uses process.exitCode for diagnostics; clear it before linting so
  // a known play failure does not mask the final capture/geometry verdict.
  process.exitCode = 0;
  const lintExitCode = await lint(["--artifact-dir", output, "--config", effectiveConfig, "--report-dir", join(output, "geometry-report"), "--expected-sha", values["expected-sha"]]);
  // Play failures remain in results.json and stderr for diagnosis, while a
  // capture that never became ready remains a hard failure.
  return captureFailed ? 1 : lintExitCode;
}
if (import.meta.main) process.exitCode = await audit();
