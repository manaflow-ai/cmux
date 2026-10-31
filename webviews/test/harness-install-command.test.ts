// The Harnesses page's Install (cx-uj5g8) runs a harness's install command in the user's login
// shell. A Mac without Node has no npm: Install uses the vendor's own installer there, and npm
// wherever it is, so an existing npm setup keeps its channel. Each command runs here under `sh`
// with stub programs that record what ran.
import { afterEach, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { INSTALL_COMMANDS } from "../src/agent-session/acpmux/harnesses/harnessRows";

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

/// Runs `command` with only stub programs on PATH (`npm` too when `withNpm`); each stub appends
/// its name, arguments and the env it cares about to a log. `curl` prints a script, the pipe's
/// reader (`bash` or `sh`) records it.
function run(command: string, withNpm: boolean): { code: number; log: string[] } {
  const dir = mkdtempSync(join(tmpdir(), "harness-install-"));
  dirs.push(dir);
  const log = join(dir, "log");
  writeFileSync(log, "");
  const stub = (name: string, body: string) => {
    writeFileSync(join(dir, name), `#!/bin/sh\n${body}\n`);
    chmodSync(join(dir, name), 0o755);
  };
  stub("curl", `echo "curl $*" >> "${log}"; echo 'echo installer'`);
  // Only builtins: PATH holds nothing but these stubs.
  stub("bash", `IFS= read -r script; echo "bash <$script>" >> "${log}"`);
  stub("sh", `IFS= read -r script; echo "sh <$script> CODEX_NON_INTERACTIVE=$CODEX_NON_INTERACTIVE" >> "${log}"`);
  if (withNpm) stub("npm", `echo "npm $*" >> "${log}"`);
  const result = Bun.spawnSync(["/bin/sh", "-c", command], { env: { PATH: dir, HOME: dir } });
  return {
    code: result.exitCode,
    log: readFileSync(log, "utf8").trim().split("\n").filter(Boolean),
  };
}

test("without npm, Install runs each vendor's own installer", () => {
  expect(run(INSTALL_COMMANDS.claude!, false)).toEqual({
    code: 0,
    log: ["curl -fsSL https://claude.ai/install.sh", "bash <echo installer>"],
  });
  expect(run(INSTALL_COMMANDS.codex!, false)).toEqual({
    code: 0,
    // Never a prompt: no tty, and it must not start Codex or remove another install.
    log: ["curl -fsSL https://chatgpt.com/codex/install.sh", "sh <echo installer> CODEX_NON_INTERACTIVE=1"],
  });
  expect(run(INSTALL_COMMANDS.opencode!, false)).toEqual({
    code: 0,
    log: ["curl -fsSL https://opencode.ai/install", "bash <echo installer>"],
  });
});

test("with npm, Install keeps npm, and never also runs a vendor installer", () => {
  expect(run(INSTALL_COMMANDS.claude!, true)).toEqual({ code: 0, log: ["npm install -g @anthropic-ai/claude-code"] });
  expect(run(INSTALL_COMMANDS.codex!, true)).toEqual({ code: 0, log: ["npm install -g @openai/codex"] });
  expect(run(INSTALL_COMMANDS.opencode!, true)).toEqual({ code: 0, log: ["npm install -g opencode-ai"] });
});
