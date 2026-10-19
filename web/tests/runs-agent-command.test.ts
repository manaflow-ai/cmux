import { expect, test } from "bun:test";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { variantAgentCommand } from "../services/runs/agentCommand";

const ATTEMPT = "4429d817-69f4-429c-9524-34e8fcd2591c";

// The devbox image pins codex 0.162.1 (CMUX_IMAGE_CODEX_VERSION). That release
// exits 2 with "unexpected argument '--full-auto' found", so a flag it rejects
// fails every instruction-bearing Run before the agent starts.
const PINNED_CODEX_FLAGS = new Set(["--json", "--dangerously-bypass-approvals-and-sandbox", "--skip-git-repo-check"]);

function runWithStubCodex(instruction: string) {
  const dir = mkdtempSync(path.join(tmpdir(), "cmux-run-agent-"));
  try {
    const argvFile = path.join(dir, "argv.json");
    const stub = path.join(dir, "codex");
    writeFileSync(stub, `#!/usr/bin/env node
const args = process.argv.slice(2);
require("node:fs").writeFileSync(${JSON.stringify(argvFile)}, JSON.stringify(args));
const allowed = new Set(${JSON.stringify([...PINNED_CODEX_FLAGS])});
const bad = args.slice(1).find((arg) => arg.startsWith("-") && !allowed.has(arg));
if (args[0] !== "exec" || bad) { console.error("error: unexpected argument '" + bad + "' found"); process.exit(2); }
console.log(JSON.stringify({ type: "thread.started", thread_id: "t" }));
`);
    chmodSync(stub, 0o755);
    const command = variantAgentCommand(instruction, ATTEMPT, dir);
    const result = spawnSync("bash", ["-se"], { input: command, env: { ...process.env, PATH: `${dir}:${process.env.PATH}` }, encoding: "utf8" });
    const argv = JSON.parse(readFileSync(argvFile, "utf8")) as string[];
    const output = readFileSync(path.join(dir, `cmux-agent-output-${ATTEMPT}.jsonl`), "utf8");
    return { status: result.status, stderr: result.stderr, argv, output };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("variant instruction starts the pinned codex non-interactively and keeps its JSON output", () => {
  const run = runWithStubCodex("Fix the failing test");
  expect(run.stderr).toBe("");
  expect(run.status).toBe(0);
  expect(run.argv).toEqual(["exec", "--json", "--dangerously-bypass-approvals-and-sandbox", "Fix the failing test"]);
  expect(run.output).toContain("thread.started");
});

test("variant instruction reaches codex as one literal argument", () => {
  const instruction = "it's $(touch /tmp/pwned) `id`\nline two; exit 1";
  const run = runWithStubCodex(instruction);
  expect(run.status).toBe(0);
  expect(run.argv.at(-1)).toBe(instruction);
});

test("instruction text with String.replace patterns is inserted verbatim into the guest script", async () => {
  const { withVariantExecution } = await import("../services/runs/agentCommand");
  const source = "set -eu\n# CMUX_VARIANT_EXECUTION\nprintf '%s\\n' 'cmux-run:marker'";
  for (const instruction of ["keep $& and $' and $` literal", "plain"]) {
    const script = withVariantExecution(source, instruction, ATTEMPT);
    expect(script).toContain(`'${instruction.replace(/'/g, `'"'"'`)}'`);
    expect(script.endsWith("printf '%s\\n' 'cmux-run:marker'")).toBe(true);
  }
  expect(withVariantExecution(source, undefined, ATTEMPT)).toBe(source.replace("# CMUX_VARIANT_EXECUTION", ""));
});
