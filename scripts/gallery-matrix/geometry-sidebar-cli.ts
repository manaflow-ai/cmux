#!/usr/bin/env bun
import { createHash } from "node:crypto";
import { copyFile, mkdir, readFile, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { PNG } from "pngjs";
import { parseSidebarStates, sidebarArtifact, sidebarConfig, type SidebarContract } from "./geometry-sidebar";
import { main as lint } from "./geometry-lint";

export async function sidebarAudit(args = process.argv.slice(2)): Promise<number> {
  const { values } = parseArgs({ args, options: { "artifact-dir": { type: "string" }, "output-dir": { type: "string" }, "expected-sha": { type: "string" }, "geometry-sha256": { type: "string" }, contract: { type: "string", default: join(import.meta.dir, "geometry-sidebar-contract.json") } } });
  if (!values["artifact-dir"] || !values["output-dir"] || !/^[a-f0-9]{40}$/.test(values["expected-sha"] ?? "") || !/^[a-f0-9]{64}$/.test(values["geometry-sha256"] ?? "")) throw new Error("artifact/output directories, exact source SHA and geometry SHA-256 are required");
  const input = resolve(values["artifact-dir"]); const output = resolve(values["output-dir"]);
  if (input === output) throw new Error("converted evidence must have a separate output directory");
  await mkdir(output, { recursive: true });
  try {
    const bytes = await readFile(join(input, "geometry.json"));
    const hash = createHash("sha256").update(bytes).digest("hex");
    if (hash !== values["geometry-sha256"]) throw new Error("native geometry SHA-256 mismatch");
    const contract: SidebarContract = JSON.parse(await readFile(values.contract!, "utf8"));
    const states = parseSidebarStates(JSON.parse(bytes.toString()), contract);
    const revision = { sha: values["expected-sha"]!, source: `native view-frame capture; geometry SHA-256 ${hash}` };
    for (const state of states) {
      const path = join(input, state.image); const pngBytes = await readFile(path); const png = PNG.sync.read(pngBytes);
      const artifact = sidebarArtifact(state, revision, { sha256: createHash("sha256").update(pngBytes).digest("hex"), width: png.width, height: png.height }, contract);
      await copyFile(path, join(output, state.image));
      await writeFile(join(output, `${artifact.capture.caseId}.geometry.json`), JSON.stringify(artifact, null, 2));
    }
    const configPath = join(output, "config.json");
    await writeFile(configPath, JSON.stringify(sidebarConfig(states, revision, contract), null, 2));
    return lint(["--artifact-dir", output, "--config", configPath, "--report-dir", join(output, "report"), "--expected-sha", revision.sha]);
  } catch (error) {
    await writeFile(join(output, "conversion-error.json"), JSON.stringify({ passed: false, error: error instanceof Error ? error.message : String(error) }, null, 2));
    return 1;
  }
}
if (import.meta.main) process.exitCode = await sidebarAudit();
