import { describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { GUEST_CMUX_SHIM } from "../services/vms/guestCli";
import { runChild } from "./helpers/run-child";

setDefaultTimeout(30000);

const source = readFileSync(join(import.meta.dirname, "../services/vms/images/devbox/agent-config.sh"), "utf8");
const opener = readFileSync(join(import.meta.dirname, "../services/vms/images/devbox/cmux-opencode"), "utf8");
const quote = (s: string) => `'${s.replaceAll("'", "'\\''")}'`;
async function fixture(body: (home: string, run: (command: string, env?: Record<string, string>, input?: string) => ReturnType<typeof runChild>) => Promise<void>) {
  const home = mkdtempSync(join(tmpdir(), "cmux-login-"));
  const bin = join(home, "bin");
  mkdirSync(bin);
  const writeBin = (name: string, text: string) => writeFileSync(join(bin, name), text, { mode: 0o755 });
  writeFileSync(join(home, "agent-config.sh"), source);
  writeBin("cmux", GUEST_CMUX_SHIM.replaceAll("/etc/cmux/agent-config.sh", join(home, "agent-config.sh")));
  writeBin("cmux-tui", "#!/bin/sh\nexit 0\n");
  for (const agent of ["codex", "claude", "pi", "hermes", "opencode-real"]) {
    writeBin(agent, `#!/bin/sh
printf 'REAL %s\\n' '${agent}' "$@"
printf 'ENV %s|%s|%s|%s\\n' "\${OPENAI_BASE_URL-}" "\${ANTHROPIC_BASE_URL-}" "\${OPENAI_API_KEY-}" "\${CMUX_BROWSER_TARGET-}"
`);
  }
  writeBin("opencode", opener.replaceAll("/etc/cmux/agent-config.sh", join(home, "agent-config.sh")).replaceAll("/usr/local/libexec/cmux-opencode-real", join(bin, "opencode-real")));
  writeBin("curl", `#!/bin/sh
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2 ;; -w|--connect-timeout|--max-time|-H|--cacert) shift 2 ;; *) url="$1"; shift ;; esac
done
printf '%s\\n' "$url" >> "$HOME/requests"
case "$url" in
  */api/coderouter/accounts|*/api/coderouter/claude-upstream) printf '%s' "\${ACCOUNTS}" > "$out"; printf '%s' "\${HTTP_STATUS:-200}" ;;
  *) printf '{}' > "$out"; printf 404 ;;
esac
`);
  for (const alias of ["cx", "oc", "p", "h"]) writeBin(alias, "#!/bin/sh\nexit 127\n");
  const run = (command: string, env: Record<string, string> = {}, input?: string) => runChild("bash", ["-c", `. ${quote(join(home, "agent-config.sh"))}; ${command}`], {
    input, timeout: 25000,
    env: { HOME: home, PATH: `${bin}:${process.env.PATH}`, CMUX_TUI_BIN: join(bin, "cmux-tui"), LANG: "en_US.UTF-8", ACCOUNTS: '{"accounts":[]}', ...env },
  });
  try { await body(home, run); } finally { rmSync(home, { recursive: true, force: true }); }
}
const route = { CMUX_CODEROUTER_URL: "https://edge.example", OPENAI_BASE_URL: "https://edge.example/v1", OPENAI_API_KEY: "cmux-vm-edge-placeholder", ANTHROPIC_BASE_URL: "https://edge.example", ANTHROPIC_API_KEY: "cmux-vm-edge-placeholder" };

describe("Cloud agent login regressions", () => {
  test.each(["codex", "claude", "opencode", "pi", "hermes"])("accountless baked route guides %s", (agent) => fixture(async (_home, run) => {
    const result = await run(agent, route);
    expect(result.status).toBe(1);
    expect(result.stdout).not.toContain("REAL");
    expect(result.stderr).toContain("shared CodeRouter account");
  }));
  test.each(["cx", "oc", "p", "h"])("shell shorthand %s reaches onboarding", (agent) => fixture(async (_home, run) => {
    const result = await run(agent);
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("shared CodeRouter account");
  }));
  test.each(["login status", "login --with-api-key", "login --device-auth", "--help", "logout"])("Codex %s remains usable headlessly", (args) => fixture(async (_home, run) => {
    const result = await run(`codex ${args}`, {}, "test-key\n");
    expect(result.status).toBe(0);
    expect(result.stdout).toContain("REAL codex");
  }));
  test.each(["claude auth login", "opencode auth login", "hermes login"])("explicit native %s bypasses onboarding", (command) => fixture(async (_home, run) => {
    const result = await run(command, route);
    expect(result.status).toBe(0);
    expect(result.stdout).toContain("REAL");
    expect(result.stdout).not.toContain("edge.example");
    expect(result.stdout).not.toContain("cmux-vm-edge-placeholder");
  }));
  test("Desktop Codex login opens on the VM without a cmux terminal id", () => fixture(async (_home, run) => {
    const result = await run("codex login", { DISPLAY: ":1" });
    expect(result.status).toBe(0);
    expect(result.stdout).toContain("|vm");
  }));
  test("direct OpenCode executable shares onboarding", () => fixture(async (_home, run) => {
    const result = await run("command opencode run hello");
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("shared CodeRouter account");
    expect(result.stdout).not.toContain("REAL");
  }));
  test("native choice launches once, persists, and overrides the generated Codex route", () => fixture(async (home, run) => {
    const login = await run("cmux agent login codex --device-auth", route);
    expect(login.status).toBe(0);
    expect(login.stdout).toContain("REAL --device-auth");
    expect(login.stdout).not.toContain("edge.example");
    mkdirSync(join(home, ".codex"), { recursive: true });
    writeFileSync(join(home, ".codex/auth.json"), '{"tokens":{"access_token":"test-token"}}');
    const launch = await run("codex exec hello", route);
    expect(launch.status).toBe(0);
    expect(launch.stdout).toContain('model_provider="openai"');
    expect(launch.stdout).not.toContain("edge.example");
  }));
  test.each(["404", "503", "000"])("unknown CodeRouter status %s preserves existing routes", (status) => fixture(async (_home, run) => {
    const result = await run("codex exec hello", { ...route, HTTP_STATUS: status });
    expect(result.status).toBe(0);
    expect(result.stdout).toContain("REAL codex");
  }));
  test("a shared account and native credentials remain usable", () => fixture(async (home, run) => {
    const shared = await run("codex exec hello", { ...route, ACCOUNTS: '{"accounts":[{"provider":"codex","state":"active"}]}' });
    expect(shared.status).toBe(0);
    mkdirSync(join(home, ".codex"), { recursive: true });
    writeFileSync(join(home, ".codex/auth.json"), '{"tokens":{"access_token":"test-token"}}');
    const native = await run("codex exec hello");
    expect(native.status).toBe(0);
  }));
  test("empty native auth does not suppress onboarding", () => fixture(async (home, run) => {
    mkdirSync(join(home, ".codex"), { recursive: true });
    writeFileSync(join(home, ".codex/auth.json"), '{}');
    const result = await run("codex");
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("shared CodeRouter account");
  }));
});
