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
/// `drops`: the first download fails with curl's "could not resolve host" while the network is
/// down, and the network check (`curl -o /dev/null`) fails that many times before it answers.
function run(command: string, withNpm: boolean, curlExit = 0, drops = 0): { code: number; log: string[] } {
  const dir = mkdtempSync(join(tmpdir(), "harness-install-"));
  dirs.push(dir);
  const log = join(dir, "log");
  writeFileSync(log, "");
  const stub = (name: string, body: string) => {
    writeFileSync(join(dir, name), `#!/bin/sh\n${body}\n`);
    chmodSync(join(dir, name), 0o755);
  };
  const curlScript = curlExit
    ? `echo "curl: simulated download failure" >&2; exit ${curlExit}`
    : "echo 'echo installer'";
  writeFileSync(join(dir, "downs"), String(drops));
  writeFileSync(join(dir, "fails"), drops ? "1" : "0");
  // The network check answers once `downs` is spent; one download fails while `fails` is set.
  const probe = `case "$*" in *"-o /dev/null"*) echo "probe" >> "${log}"; d=$(cat "${dir}/downs"); [ "$d" -gt 0 ] && { echo $((d - 1)) > "${dir}/downs"; exit 7; }; exit 0;; esac`;
  const dropped = `if [ "$(cat "${dir}/fails")" = 1 ]; then echo 0 > "${dir}/fails"; echo "curl: (6) Could not resolve host" >&2; exit 6; fi`;
  stub("curl", `${probe}; echo "curl $*" >> "${log}"; ${dropped}; ${curlScript}`);
  // The wait between network checks takes no time here.
  stub("sleep", "exit 0");
  stub("brew", `echo "brew $*" >> "${log}"`);
  stub("cargo", `echo "cargo $*" >> "${log}"`);
  // Only builtins: PATH holds nothing but these stubs.
  stub("bash", `IFS= read -r script; echo "bash <$script>" >> "${log}"`);
  // Keep the expected log stable even when the parent test runner exports the
  // Codex installer flag. Only the Codex command intentionally sets it.
  stub(
    "sh",
    `IFS= read -r script; if [ -n "$CODEX_NON_INTERACTIVE" ]; then echo "sh <$script> CODEX_NON_INTERACTIVE=$CODEX_NON_INTERACTIVE" >> "${log}"; else echo "sh <$script>" >> "${log}"; fi`,
  );
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
  expect(run(INSTALL_COMMANDS.gemini!, false)).toEqual({
    code: 0,
    log: ["brew install gemini-cli"],
  });
  // Muse uses its existing setup/docs action; it has no second install command
  // that could duplicate the provider's official setup flow.
  expect(INSTALL_COMMANDS.muse).toBeUndefined();
});

// The script reader succeeds with an empty input; a failed curl must still fail Install.
test("without npm, offline and HTTP failures are reported by every vendor installer", () => {
  for (const harness of ["claude", "codex", "opencode"] as const) {
    for (const curlExit of [6, 22]) {
      const result = run(INSTALL_COMMANDS[harness]!, false, curlExit);
      expect(result.code).toBe(curlExit);
      expect(result.log.some((line) => line.startsWith("curl -fsSL "))).toBe(true);
    }
  }
});

test("with npm, Install keeps npm, and never also runs a vendor installer", () => {
  expect(run(INSTALL_COMMANDS.claude!, true)).toEqual({ code: 0, log: ["npm install -g @anthropic-ai/claude-code"] });
  expect(run(INSTALL_COMMANDS.codex!, true)).toEqual({ code: 0, log: ["npm install -g @openai/codex"] });
  expect(run(INSTALL_COMMANDS.opencode!, true)).toEqual({ code: 0, log: ["npm install -g opencode-ai"] });
  // Gemini keeps npm when it is available; Muse uses its setup/docs action.
  expect(run(INSTALL_COMMANDS.gemini!, true)).toEqual({
    code: 0,
    log: ["npm install -g @google/gemini-cli"],
  });
  expect(INSTALL_COMMANDS.muse).toBeUndefined();
});

// First-run finding 6: the network dropped for 20 s during the Claude Code install and it stayed
// failed. Each real install command now waits for the network and runs again by itself.
test("without npm, a download the network dropped waits for the network, then installs by itself", () => {
  for (const harness of ["claude", "codex", "opencode"] as const) {
    const result = run(INSTALL_COMMANDS[harness]!, false, 0, 2);
    expect({ harness, code: result.code }).toEqual({ harness, code: 0 });
    const downloads = result.log.filter((line) => line.startsWith("curl -fsSL "));
    expect({ harness, downloads: downloads.length }).toEqual({ harness, downloads: 2 });
    // It checked the network until it answered, then ran the installer it downloaded.
    expect(result.log.filter((line) => line === "probe").length).toBeGreaterThanOrEqual(3);
    expect(result.log.at(-1)).toMatch(/^(bash|sh) <echo installer>/);
  }
});
