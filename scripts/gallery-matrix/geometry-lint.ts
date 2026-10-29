#!/usr/bin/env bun
import { readFile, readdir, mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { lintGeometry, parseArtifact, parseConfig, validateScreenshot } from "./geometry";

async function files(root: string): Promise<string[]> {
  const found: string[] = [];
  for (const entry of await readdir(root, { withFileTypes: true })) {
    const path = join(root, entry.name);
    if (entry.isDirectory()) found.push(...await files(path));
    else if (entry.isFile() && entry.name.endsWith(".geometry.json")) found.push(path);
  }
  return found.sort();
}

export async function main(args = process.argv.slice(2)): Promise<number> {
  const { values } = parseArgs({ args, options: { "artifact-dir": { type: "string" }, config: { type: "string" }, "report-dir": { type: "string" }, "expected-sha": { type: "string" } } });
  if (!values["artifact-dir"] || !values.config || !values["report-dir"] || !values["expected-sha"]) throw new Error("--artifact-dir, --config, --report-dir and --expected-sha are required");
  const config = parseConfig(JSON.parse(await readFile(values.config, "utf8")), values.config);
  const artifacts: Array<{ file: string; artifact: ReturnType<typeof parseArtifact> }> = [];
  const parseErrors: string[] = [];
  for (const file of await files(values["artifact-dir"])) {
    try {
      artifacts.push({ file, artifact: parseArtifact(JSON.parse(await readFile(file, "utf8")), file) });
    } catch (error) {
      parseErrors.push(`${file}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  await mkdir(values["report-dir"], { recursive: true });
  const report = await lintGeometry(artifacts, config, values["report-dir"]);
  report.errors.push(...parseErrors);
  for (const { file, artifact } of artifacts) {
    report.errors.push(...await validateScreenshot(file, artifact));
    if (artifact.revision.sha !== values["expected-sha"]) report.errors.push(`${file}: capture SHA does not match --expected-sha`);
  }
  report.passed = report.passed && report.errors.length === 0;
  await writeFile(join(values["report-dir"], "geometry-report.json"), `${JSON.stringify(report, null, 2)}\n`);
  const failures = report.findings.filter((finding) => !finding.accepted);
  for (const error of report.errors) console.error(`geometry error: ${error}`);
  for (const finding of failures) console.error(`geometry ${finding.id}: ${finding.message}${finding.deltaPx === undefined ? "" : ` (${finding.deltaPx}px)`}`);
  console.log(`geometry: ${report.artifacts} captures, ${report.findings.length} findings, ${failures.length} unaccepted, ${report.errors.length} errors`);
  return report.passed ? 0 : 1;
}

if (import.meta.main) process.exitCode = await main();
