import { afterEach, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { renderVmGuestModelPlaneEnvFile, vmGuestModelPlaneEnv, VM_PLACEHOLDER_API_KEY } from "../services/coderouter/vmGuestEnv";
import { workUserExecCommand } from "../services/vms/drivers/workUserExecCommand";
import { GUEST_CMUX_SHIM } from "../services/vms/guestCli";
import { runChild } from "./helpers/run-child";

// Agent readiness (`cmux vm doctor`, the pre-launch check of `vm agent`, the
// app's Agents section) runs one names-only script on a machine over vm.exec.
// Its source of truth is the Swift string in
// Packages/macOS/CmuxCloud/Sources/CmuxCloud/AgentReadiness/CloudAgentReadinessRequest.swift;
// this file runs those exact bytes the way the Mac does (`sh -c <script>
// cmux-agent-readiness <agent> <probe> <fast>` behind the work-user exec
// prelude) against a machine with today's baked agent-auth.sh, and checks
// what it reports and what it never does: print a value, put one in an
// argument, or send a key anywhere but the constant URL of that key's own
// provider.

setDefaultTimeout(30_000);

const repoRoot = path.join(import.meta.dirname, "../..");

function swiftScript(file: string, marker: string): string {
  const source = readFileSync(path.join(repoRoot, file), "utf8");
  const start = source.indexOf(`static let ${marker} = #"""\n`);
  const end = source.indexOf('\n"""#', start);
  if (start < 0 || end < 0) throw new Error(`${marker} not found in ${file}`);
  return source.slice(start + `static let ${marker} = #"""\n`.length, end) + "\n";
}

const SCRIPT = swiftScript("Packages/macOS/CmuxCloud/Sources/CmuxCloud/AgentReadiness/CloudAgentReadinessRequest.swift", "script");
const GUARD = swiftScript("Sources/Cloud/CloudSecretsService+Sync.swift", "guardScript");

const ALIAS = "coderouter.cmux.test";
const ORIGIN = `https://${ALIAS}`;
const ANTHROPIC_KEY = "sk-ant-readiness-secret-1";
const OPENAI_KEY = "sk-proj-readiness-secret-2";
const GH_KEY = "ghp_readinessSecret3";
const SECRETS = [ANTHROPIC_KEY, OPENAI_KEY, GH_KEY];
const templateDir = path.join(import.meta.dirname, "../services/vms/images/devbox");

const roots: string[] = [];
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

type Machine = { root: string; home: string; etc: string; bin: string; envFile: string; curlLog: string; codex: string };

/**
 * A machine on today's image: the baked plane and agent-auth.sh, the agent
 * CLIs as stubs, the guest shim as `cmux` (the guard writes through it), and a
 * fake `curl` that logs every argument list and every config it read on
 * stdin, answers the account check, and answers a provider with
 * FAKE_<HOST>_STATUS (default 200).
 */
function machine(options: { teamAgents?: Record<string, boolean>; codexConfig?: boolean } = {}): Machine {
  const root = mkdtempSync(path.join(tmpdir(), "cmux-agent-readiness-"));
  roots.push(root);
  const home = path.join(root, "home");
  const etc = path.join(root, "etc");
  const bin = path.join(root, "bin");
  for (const dir of [home, etc, bin, path.join(home, ".config/cmux"), path.join(home, ".codex")]) mkdirSync(dir, { recursive: true });
  writeFileSync(path.join(etc, "model-plane.env"), renderVmGuestModelPlaneEnvFile(vmGuestModelPlaneEnv(ALIAS)));
  writeFileSync(path.join(etc, "agent-auth.sh"), readFileSync(path.join(templateDir, "agent-auth.sh"), "utf8"));
  writeFileSync(path.join(etc, "tool-versions"), "claude 2.1.300 · codex 0.162.1 · opencode 1.2.3 · pi 0.9.0\n");
  for (const agent of ["claude", "codex", "opencode", "pi", "gh"]) {
    writeFileSync(path.join(bin, agent), "#!/bin/sh\nexit 0\n");
    chmodSync(path.join(bin, agent), 0o755);
  }
  writeFileSync(path.join(bin, "cmux"), GUEST_CMUX_SHIM);
  chmodSync(path.join(bin, "cmux"), 0o755);
  writeFileSync(path.join(bin, "cmux-tui"), "#!/bin/sh\nexit 0\n");
  chmodSync(path.join(bin, "cmux-tui"), 0o755);
  // The exec prelude takes HOME from `getent passwd "$(id -u)"`. A Linux host
  // answers with the runner's real home and would move the check off this
  // machine's home; answer with it instead (macOS has no getent at all).
  writeFileSync(path.join(bin, "getent"), `#!/bin/sh\n[ "$1" = passwd ] || exit 2\nprintf '%s\\n' 'cmux:x:1000:1000::${home}:/bin/sh'\n`);
  chmodSync(path.join(bin, "getent"), 0o755);
  const curlLog = path.join(root, "curl.log");
  const team = JSON.stringify({ teamId: "t", agents: options.teamAgents ?? { claude: true, codex: true, opencode: true } });
  writeFileSync(
    path.join(bin, "curl"),
    [
      "#!/bin/sh",
      `log=${JSON.stringify(curlLog)}`,
      `printf 'ARGV %s\\n' "$*" >> "$log"`,
      // Only a `-K -` caller hands curl a config on stdin.
      `case " $* " in *" -K - "*) printf 'STDIN %s\\n' "$(cat)" >> "$log" ;; esac`,
      'case "$*" in',
      `  */api/coderouter/agent-access*) printf '%s' ${JSON.stringify(team)} ;;`,
      '  *api.anthropic.com*) printf "%s" "${FAKE_ANTHROPIC_STATUS:-200}" ;;',
      '  *api.openai.com*) printf "%s" "${FAKE_OPENAI_STATUS:-200}" ;;',
      '  *api.github.com*) printf "%s" "${FAKE_GITHUB_STATUS:-200}" ;;',
      '  *) printf "000"; exit 7 ;;',
      "esac",
      "",
    ].join("\n"),
  );
  chmodSync(path.join(bin, "curl"), 0o755);
  const codex = path.join(home, ".codex/config.toml");
  if (options.codexConfig !== false) {
    writeFileSync(codex, `model_provider = "cmux"\n\n[model_providers.cmux]\nname = "cmux"\nbase_url = "${ORIGIN}/v1"\nenv_key = "OPENAI_API_KEY"\n`);
  }
  return { root, home, etc, bin, envFile: path.join(home, ".config/cmux/env"), curlLog, codex };
}

function setEnv(m: Machine, entries: Record<string, string>) {
  const quote = (value: string) => `'${value.replace(/'/g, `'\\''`)}'`;
  writeFileSync(m.envFile, Object.entries(entries).map(([k, v]) => `export ${k}=${quote(v)}\n`).join(""), { mode: 0o600 });
}

function baseEnv(m: Machine, extra: Record<string, string> = {}): Record<string, string> {
  return {
    PATH: `${m.bin}:${process.env.PATH ?? "/usr/bin:/bin"}`,
    HOME: m.home,
    CMUX_ROUTING_ETC: m.etc,
    GIT_CONFIG_NOSYSTEM: "1",
    LANG: "C",
    ...extra,
  };
}

const shellWord = (value: string) => `'${value.replace(/'/g, `'\\''`)}'`;

type Row = Record<string, string>;

/** Runs the check the way the Mac does and parses its rows. */
async function readiness(m: Machine, options: { agent?: string; probe?: boolean; fast?: boolean; env?: Record<string, string> } = {}) {
  const command = ["sh", "-c", SCRIPT, "cmux-agent-readiness", options.agent ?? "all", options.probe ? "1" : "0", options.fast ? "1" : "0"]
    .map(shellWord)
    .join(" ");
  const result = await runChild("sh", ["-c", workUserExecCommand(command)], { env: baseEnv(m, options.env) });
  expect(result.status).toBe(0);
  for (const secret of SECRETS) {
    expect(result.stdout).not.toContain(secret);
    expect(result.stderr).not.toContain(secret);
  }
  const lines = result.stdout.trim().split("\n");
  expect(lines[0]).toMatch(/^cmux-agent-readiness v1 plane=[01] auth=[01]$/);
  expect(lines[lines.length - 1]).toBe("cmux-agent-readiness end");
  const rows: Record<string, Row> = {};
  for (const line of lines.slice(1, -1)) {
    const row: Row = Object.fromEntries(line.split(" ").map((pair) => [pair.slice(0, pair.indexOf("=")), pair.slice(pair.indexOf("=") + 1)]));
    rows[row.agent] = row;
  }
  return { rows, stdout: result.stdout };
}

function curlCalls(m: Machine) {
  if (!existsSync(m.curlLog)) return { argv: [] as string[], stdin: [] as string[] };
  const lines = readFileSync(m.curlLog, "utf8").split("\n").filter(Boolean);
  return {
    argv: lines.filter((line) => line.startsWith("ARGV ")).map((line) => line.slice(5)),
    stdin: lines.filter((line) => !line.startsWith("ARGV ")),
  };
}

describe("agent readiness script", () => {
  test("is names-only: no value in the script, and it never prints one", () => {
    for (const secret of SECRETS) expect(SCRIPT).not.toContain(secret);
    expect(SCRIPT).not.toContain("set -x");
    // The probe URLs are the routing guard's provider endpoints (plus constant hosts).
    const routing = readFileSync(path.join(repoRoot, "Sources/Cloud/CloudSecretsService+Sync.swift"), "utf8");
    const anthropic = /static let anthropicEndpoint = "([^"]+)"/.exec(routing)?.[1];
    const openai = /static let openAIEndpoint = "([^"]+)"/.exec(routing)?.[1];
    expect(anthropic).toBe("https://api.anthropic.com");
    expect(openai).toBe("https://api.openai.com/v1");
    expect(SCRIPT).toContain(`url=${anthropic}/v1/models`);
    expect(SCRIPT).toContain(`url=${openai}/models`);
    // Every probe URL is a literal https constant, never a variable read from the machine.
    for (const match of SCRIPT.matchAll(/\burl=([^;\s]+)/g)) expect(match[1]).toMatch(/^https:\/\/[a-z0-9.-]+\//);
  });

  test("reports install, version, mode and credential source for every agent", async () => {
    const m = machine({ teamAgents: { claude: true, codex: false, opencode: true } });
    setEnv(m, { ANTHROPIC_API_KEY: ANTHROPIC_KEY, ANTHROPIC_BASE_URL: "https://api.anthropic.com" });
    const { rows } = await readiness(m);
    expect(Object.keys(rows)).toEqual(["claude", "codex", "opencode", "pi", "gh"]);
    expect(rows.claude).toMatchObject({ installed: "1", version: "2.1.300", source: "key", key: "ANTHROPIC_API_KEY", endpoint: "provider", host: "api.anthropic.com", probe: "-" });
    // No key, no sign-in, and the team has no codex account: nothing to start with.
    expect(rows.codex).toMatchObject({ source: "none", mode: "own", reason: "no-team-account" });
    expect(rows.opencode).toMatchObject({ source: "routing", mode: "team", reason: "team-account", endpoint: "cmux", host: ALIAS });
    expect(rows.pi).toMatchObject({ version: "0.9.0", source: "key", key: "ANTHROPIC_API_KEY", host: "api.anthropic.com" });
    expect(rows.gh).toMatchObject({ source: "none" });
    // Without --probe, the only request is the launchers' own account check, with the placeholder.
    const calls = curlCalls(m);
    expect(calls.argv.every((argv) => argv.includes("/api/coderouter/agent-access"))).toBe(true);
    expect(calls.argv.join("\n")).toContain(`Bearer ${VM_PLACEHOLDER_API_KEY}`);
  });

  test("probe sends a key only to its provider's constant URL, on stdin, and reports only the status", async () => {
    const m = machine();
    setEnv(m, { ANTHROPIC_API_KEY: ANTHROPIC_KEY, ANTHROPIC_BASE_URL: "https://api.anthropic.com", GH_TOKEN: GH_KEY });
    const { rows } = await readiness(m, { probe: true, env: { FAKE_ANTHROPIC_STATUS: "401" } });
    expect(rows.claude.probe).toBe("401");
    expect(rows.pi.probe).toBe("401");
    expect(rows.gh).toMatchObject({ source: "key", key: "GH_TOKEN", endpoint: "provider", probe: "200" });
    const calls = curlCalls(m);
    const probes = calls.argv.filter((argv) => !argv.includes("agent-access"));
    // claude and pi share the key: one request.
    expect(probes.length).toBe(2);
    expect(probes.every((argv) => argv.includes("-K - "))).toBe(true);
    expect(probes[0]).toEndWith("https://api.anthropic.com/v1/models");
    expect(probes[1]).toEndWith("https://api.github.com/rate_limit");
    for (const argv of calls.argv) for (const secret of SECRETS) expect(argv).not.toContain(secret);
    const stdin = calls.stdin.join("\n");
    expect(stdin).toContain(`header = "x-api-key: ${ANTHROPIC_KEY}"`);
    expect(stdin).toContain(`header = "Authorization: Bearer ${GH_KEY}"`);
    expect(probes.every((argv) => argv.includes("--proto =https") && argv.includes("--max-redirs 0"))).toBe(true);
  });

  test("a key bound for cmux model routing is reported and never probed", async () => {
    const m = machine();
    setEnv(m, { ANTHROPIC_API_KEY: ANTHROPIC_KEY, ANTHROPIC_BASE_URL: ORIGIN });
    const { rows } = await readiness(m, { agent: "claude", probe: true });
    expect(Object.keys(rows)).toEqual(["claude"]);
    expect(rows.claude).toMatchObject({ source: "key", endpoint: "cmux", host: ALIAS, probe: "-" });
    expect(curlCalls(m).stdin).toEqual([]);
  });

  test("a key with no provider endpoint beside it on a routed machine is unrouted", async () => {
    const m = machine();
    setEnv(m, { ANTHROPIC_API_KEY: ANTHROPIC_KEY });
    const { rows } = await readiness(m, { agent: "claude" });
    expect(rows.claude).toMatchObject({ source: "key", endpoint: "unrouted", host: "api.anthropic.com" });
  });

  test("a user's own endpoint shows its host only and is never probed", async () => {
    const m = machine();
    setEnv(m, { ANTHROPIC_API_KEY: ANTHROPIC_KEY, ANTHROPIC_BASE_URL: "https://user:pass@proxy.example.com/v1?key=abc#x" });
    const { rows, stdout } = await readiness(m, { agent: "claude", probe: true });
    expect(rows.claude).toMatchObject({ endpoint: "custom", host: "proxy.example.com", probe: "-" });
    expect(stdout).not.toContain("pass");
    expect(stdout).not.toContain("key=abc");
    expect(curlCalls(m).stdin).toEqual([]);
  });

  test("codex: the routing guard turns a key on the model router's provider into a direct one", async () => {
    const m = machine();
    setEnv(m, { OPENAI_API_KEY: OPENAI_KEY });
    // Today's image's launcher predates the per-launch precedence: before the
    // guard, codex's cmux provider would authenticate the router with the key.
    let { rows } = await readiness(m, { agent: "codex", probe: true });
    expect(rows.codex).toMatchObject({ source: "key", key: "OPENAI_API_KEY", endpoint: "cmux", host: ALIAS, probe: "-" });
    expect(curlCalls(m).stdin).toEqual([]);

    const guard = await runChild("sh", ["-c", GUARD, "cmux-provider-routing", "direct", "plane"], { env: baseEnv(m) });
    expect(guard.status).toBe(0);
    expect(readFileSync(m.codex, "utf8")).toContain('model_provider = "cmux-openai-key"');

    ({ rows } = await readiness(m, { agent: "codex", probe: true, env: { FAKE_OPENAI_STATUS: "200" } }));
    expect(rows.codex).toMatchObject({ source: "key", endpoint: "provider", host: "api.openai.com", probe: "200" });
    const probes = curlCalls(m).argv.filter((argv) => argv.includes("-K -"));
    expect(probes.length).toBe(1);
    expect(probes[0]).toEndWith(" https://api.openai.com/v1/models");
  });

  test("own sign-ins count without reading them", async () => {
    const m = machine({ teamAgents: { claude: false, codex: false, opencode: false } });
    mkdirSync(path.join(m.home, ".claude"), { recursive: true });
    writeFileSync(path.join(m.home, ".claude/.credentials.json"), JSON.stringify({ claudeAiOauth: { accessToken: "oauth-secret-value" } }));
    mkdirSync(path.join(m.home, ".config/gh"), { recursive: true });
    writeFileSync(path.join(m.home, ".config/gh/hosts.yml"), "github.com:\n    oauth_token: gho_hosts-secret\n    user: someone\n");
    const { rows, stdout } = await readiness(m);
    expect(rows.claude).toMatchObject({ source: "login", mode: "own", reason: "login", endpoint: "provider" });
    expect(rows.gh).toMatchObject({ source: "login" });
    expect(stdout).not.toContain("oauth-secret-value");
    expect(stdout).not.toContain("gho_hosts-secret");
  });

  test("fast mode never touches the network, even with probe, and reads the cached account answer", async () => {
    const m = machine();
    setEnv(m, { ANTHROPIC_API_KEY: ANTHROPIC_KEY, ANTHROPIC_BASE_URL: "https://api.anthropic.com" });
    mkdirSync(path.join(m.home, ".cache/cmux"), { recursive: true });
    writeFileSync(path.join(m.home, ".cache/cmux/agent-access"), `${Math.floor(Date.now() / 1000)} 0 1 0\n`);
    const { rows } = await readiness(m, { probe: true, fast: true });
    expect(rows.claude).toMatchObject({ source: "key", probe: "-" });
    expect(rows.codex).toMatchObject({ source: "none", reason: "no-team-account" });
    expect(rows.opencode).toMatchObject({ source: "routing", reason: "team-account" });
    expect(existsSync(m.curlLog)).toBe(false);
  });

  test("fast mode without a fresh cached answer leaves the account unknown", async () => {
    const m = machine();
    const { rows } = await readiness(m, { agent: "codex", fast: true });
    expect(rows.codex).toMatchObject({ source: "routing", mode: "team", reason: "team-unknown" });
    expect(existsSync(m.curlLog)).toBe(false);
  });

  test("a value curl's config could not carry verbatim is not sent", async () => {
    const m = machine();
    setEnv(m, { ANTHROPIC_API_KEY: 'sk-ant-"quoted"\\', ANTHROPIC_BASE_URL: "https://api.anthropic.com" });
    const { rows } = await readiness(m, { agent: "claude", probe: true });
    expect(rows.claude.probe).toBe("skipped");
    expect(curlCalls(m).stdin).toEqual([]);
  });

  test("an unreachable provider is reported as such", async () => {
    const m = machine();
    setEnv(m, { GH_TOKEN: GH_KEY });
    const { rows } = await readiness(m, { agent: "gh", probe: true, env: { FAKE_GITHUB_STATUS: "000" } });
    expect(rows.gh.probe).toBe("unreachable");
  });

  test("an older image without sign-in modes still answers", async () => {
    const m = machine();
    rmSync(path.join(m.etc, "agent-auth.sh"));
    rmSync(path.join(m.etc, "model-plane.env"));
    const { rows, stdout } = await readiness(m, { agent: "claude" });
    expect(stdout.startsWith("cmux-agent-readiness v1 plane=0 auth=0\n")).toBe(true);
    expect(rows.claude).toMatchObject({ source: "none", mode: "unknown" });
  });
});
