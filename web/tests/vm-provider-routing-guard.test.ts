import { afterEach, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readlinkSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { GUEST_CMUX_SHIM } from "../services/vms/guestCli";
import { renderVmGuestModelPlaneEnvFile, vmGuestModelPlaneEnv, VM_PLACEHOLDER_API_KEY } from "../services/coderouter/vmGuestEnv";
import { runChild } from "./helpers/run-child";

// Cloud Secrets provider routing on RUNNING machines. Their baked guest files
// (agent-config.sh, launchers, the adapter) predate the precedence "a user's
// own provider key goes to that provider directly, never to CodeRouter", and
// nothing on a machine updates itself (docs/cloud-guest-upgrades.md). The Mac
// therefore runs one names-only guard over vm.exec on every sync that needs
// it. The guard's source of truth is the Swift string in
// Sources/Cloud/CloudSecretsService+Sync.swift; this file runs those exact
// bytes against a machine running today's baked devbox files
// (services/vms/images/devbox: agent-config.sh, agent-auth.sh, launchers),
// which carry no precedence of their own, and drives their launchers after.

setDefaultTimeout(30_000);

const repoRoot = path.join(import.meta.dirname, "../..");
const swiftSource = readFileSync(path.join(repoRoot, "Sources/Cloud/CloudSecretsService+Sync.swift"), "utf8");
const GUARD = (() => {
  const start = swiftSource.indexOf('static let guardScript = #"""\n');
  const end = swiftSource.indexOf('\n"""#', start);
  if (start < 0 || end < 0) throw new Error("guard script not found in CloudSecretsService+Sync.swift");
  return swiftSource.slice(start + 'static let guardScript = #"""\n'.length, end) + "\n";
})();

const ALIAS = "coderouter.cmux.test";
const ORIGIN = `https://${ALIAS}`;
const PLACEHOLDER = VM_PLACEHOLDER_API_KEY;
const USER_KEY = "sk-proj-user-routing-key";
const OPENAI = "https://api.openai.com/v1";

const roots: string[] = [];
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

const templateDir = path.join(import.meta.dirname, "../services/vms/images/devbox");
const AGENTS = ["claude", "codex", "opencode"] as const;
type Agent = (typeof AGENTS)[number];

type Machine = {
  root: string; home: string; etc: string; bin: string; envFile: string; planeCopy: string; codex: string; calls: string;
  launchers: Record<Agent, string>;
};

/**
 * A machine on today's image: the baked plane, the baked agent-config.sh and
 * agent-auth.sh (paths pointed into this machine), the agent launchers in
 * front of fake agents that print their env and arguments, the adapter as
 * `cmux`, and a fake `curl` that answers the account check and the OpenCode
 * catalog and logs every call. `fresh` is a brand-new machine whose first
 * sync runs before its first shell: no codex config yet.
 */
function machine(options: { newLauncher?: boolean; fresh?: boolean } = {}): Machine {
  const root = mkdtempSync(path.join(tmpdir(), "cmux-routing-guard-"));
  roots.push(root);
  const home = path.join(root, "home");
  const etc = path.join(root, "etc");
  const bin = path.join(root, "bin");
  for (const dir of [home, etc, bin, path.join(home, ".config/cmux"), path.join(home, ".codex")]) mkdirSync(dir, { recursive: true });
  writeFileSync(path.join(etc, "model-plane.env"), renderVmGuestModelPlaneEnvFile(vmGuestModelPlaneEnv(ALIAS)));
  const routed = (text: string) => text
    .replaceAll("/etc/cmux/model-plane.env", path.join(etc, "model-plane.env"))
    .replaceAll("/etc/cmux/agent-config.sh", path.join(etc, "agent-config.sh"))
    .replaceAll("/etc/cmux/agent-auth.sh", path.join(etc, "agent-auth.sh"));
  writeFileSync(path.join(etc, "agent-config.sh"), routed(readFileSync(path.join(templateDir, "agent-config.sh"), "utf8")));
  writeFileSync(
    path.join(etc, "agent-auth.sh"),
    readFileSync(path.join(templateDir, "agent-auth.sh"), "utf8") + (options.newLauncher ? "cmux_codex_user_key_provider=cmux-openai-key\n" : ""),
  );
  const calls = path.join(root, "curl.calls");
  const catalog = JSON.stringify({ provider: { go: { options: { baseURL: `${ORIGIN}/api/coderouter/opencode/proxy/go`, apiKey: "crt_catalog-token" } } } });
  writeFileSync(
    path.join(bin, "curl"),
    [
      "#!/bin/sh",
      `printf '%s\\n' "$*" >> ${JSON.stringify(calls)}`,
      'case "$*" in',
      // FAKE_CATALOG_STATUS answers the catalog with that status instead (403 with the server's no-account error).
      // FAKE_CATALOG_EXIT fails the catalog request the way curl does when the alias does not resolve (6).
      `  */opencode/config*) if [ -n "\${FAKE_CATALOG_EXIT-}" ]; then exit "$FAKE_CATALOG_EXIT"; elif [ -n "\${FAKE_CATALOG_STATUS-}" ]; then printf '%s\\n%s' '{"error":{"message":"No OpenCode account is shared with this team."}}' "$FAKE_CATALOG_STATUS"; else printf '%s\\n200' ${JSON.stringify(catalog)}; fi ;;`,
      `  *) printf '%s' '{"teamId":"t","agents":{"claude":true,"codex":true,"opencode":true}}' ;;`,
      "esac",
      "",
    ].join("\n"),
  );
  chmodSync(path.join(bin, "curl"), 0o755);
  const launchers = {} as Record<Agent, string>;
  for (const agent of AGENTS) {
    const real = path.join(root, `${agent}-real`);
    writeFileSync(real, [
      "#!/bin/sh",
      ...["ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_BASE_URL", "OPENAI_API_KEY", "OPENCODE_CONFIG"]
        .map((name) => `printf "${name}=%s\\n" "\${${name}-<unset>}"`),
      'printf "args=%s\\n" "$*"',
      "",
    ].join("\n"));
    chmodSync(real, 0o755);
    launchers[agent] = path.join(root, agent);
    writeFileSync(launchers[agent], routed(readFileSync(path.join(templateDir, `cmux-${agent}`), "utf8")).replaceAll(`/usr/local/libexec/cmux-${agent}-real`, real));
    chmodSync(launchers[agent], 0o755);
  }
  writeFileSync(path.join(bin, "cmux"), GUEST_CMUX_SHIM);
  chmodSync(path.join(bin, "cmux"), 0o755);
  // Every machine has the daemon, and the shim refuses daemon verbs (`env`
  // among them) without one. `env` never calls it, so a stand-in is enough;
  // without it the result depends on whether the host has a cmux-tui on PATH.
  writeFileSync(path.join(bin, "cmux-tui"), "#!/bin/sh\nexit 0\n");
  chmodSync(path.join(bin, "cmux-tui"), 0o755);
  const codex = path.join(home, ".codex/config.toml");
  if (!options.fresh) {
    writeFileSync(codex, `model_provider = "cmux"\n\n[model_providers.cmux]\nname = "cmux"\nbase_url = "${ORIGIN}/v1"\nenv_key = "OPENAI_API_KEY"\n`);
  }
  return {
    root, home, etc, bin, codex, calls, launchers,
    envFile: path.join(home, ".config/cmux/env"),
    planeCopy: path.join(home, ".config/cmux/model-plane.env"),
  };
}

function env(m: Machine): Record<string, string> {
  return { PATH: `${m.bin}:${process.env.PATH ?? "/usr/bin:/bin"}`, HOME: m.home, CMUX_ROUTING_ETC: m.etc, LANG: "C" };
}

async function cmux(m: Machine, ...args: string[]) {
  const result = await runChild(path.join(m.bin, "cmux"), args, { env: env(m) });
  expect(result.status).toBe(0);
}

/** Runs the guard the way the Mac does: `sh -c <script> cmux-provider-routing <openai> <anthropic>`. */
/**
 * Runs the guard the way the Mac does: `sh -c <script> cmux-provider-routing <openai> <anthropic>`.
 * Its only output is one result line naming, per provider, `ok` or why that
 * provider's key must be held back; the Mac delivers everything else.
 */
async function guard(m: Machine, openai: string, anthropic: string, extra: Record<string, string> = {}) {
  const result = await runChild("sh", ["-c", GUARD, "cmux-provider-routing", openai, anthropic], { env: { ...env(m), ...extra } });
  const line = /^CMUX-ROUTING-RESULT openai=(\S+) anthropic=(\S+)\n$/.exec(result.stdout);
  expect(line).not.toBeNull();
  return { ...result, openai: line?.[1], anthropic: line?.[2] };
}

const envLine = (m: Machine, name: string) =>
  existsSync(m.envFile) ? readFileSync(m.envFile, "utf8").split("\n").find((line) => line.startsWith(`export ${name}=`)) : undefined;

describe("Cloud Secrets provider routing guard (running machines)", () => {
  test("is POSIX sh and carries no value", async () => {
    expect((await runChild("sh", ["-n"], { input: GUARD })).status).toBe(0);
    expect(GUARD).not.toMatch(/sk-|crt_/);
  });

  test("a delivered OpenAI key gets OpenAI's own endpoint, and every copy and CodeRouter config is cleaned", async () => {
    const m = machine();
    // As an older image leaves it: the key in the machine env beside the
    // plane endpoint, the key copied into this home's model-plane file, the
    // cmux codex provider, and OpenCode's CodeRouter providers reading the
    // key from OPENAI_API_KEY next to the user's own provider.
    writeFileSync(m.envFile, `export OPENAI_API_KEY='${USER_KEY}'\n`);
    writeFileSync(m.planeCopy, `export OPENAI_BASE_URL='${ORIGIN}/v1'\nexport OPENAI_API_KEY='${USER_KEY}'\n`);
    const team = path.join(m.home, ".config/cmux/opencode-team.json");
    writeFileSync(team, JSON.stringify({ provider: { go: { options: { baseURL: `${ORIGIN}/api/coderouter/opencode/proxy/go`, apiKey: "{env:OPENAI_API_KEY}" } } } }));
    mkdirSync(path.join(m.home, ".config/opencode"), { recursive: true });
    const global = path.join(m.home, ".config/opencode/opencode.json");
    const own = { provider: { mine: { options: { baseURL: OPENAI, apiKey: "{env:OPENAI_API_KEY}" } }, cmux: { options: { baseURL: `${ORIGIN}/v1`, apiKey: "{env:OPENAI_API_KEY}" } } } };
    writeFileSync(global, JSON.stringify(own));

    expect((await guard(m, "direct", "plane")).status).toBe(0);

    expect(envLine(m, "OPENAI_BASE_URL")).toBe(`export OPENAI_BASE_URL='${OPENAI}'`);
    expect(envLine(m, "OPENAI_API_KEY")).toBe(`export OPENAI_API_KEY='${USER_KEY}'`);
    // The copy is gone and can never be written again: every reader falls
    // back to the baked plane, which holds only the alias and placeholder.
    expect(lstatSync(m.planeCopy).isSymbolicLink()).toBe(true);
    expect(readlinkSync(m.planeCopy)).toBe("/dev/null");
    const codex = readFileSync(m.codex, "utf8");
    expect(codex).toContain('model_provider = "cmux-openai-key"');
    expect(codex).toContain(`[model_providers.cmux-openai-key]\nname = "OpenAI"\nbase_url = "${OPENAI}"\nenv_key = "OPENAI_API_KEY"`);
    expect(JSON.parse(readFileSync(team, "utf8")).provider.go.options.apiKey).toBe(PLACEHOLDER);
    const fixed = JSON.parse(readFileSync(global, "utf8"));
    expect(fixed.provider.cmux.options.apiKey).toBe(PLACEHOLDER);
    expect(fixed.provider.mine.options.apiKey).toBe("{env:OPENAI_API_KEY}");
    // The team file was already in place: no fetch.
    expect(existsSync(m.calls)).toBe(false);
    // A shell that sources the machine env after the plane sends the key to OpenAI.
    const shell = await runChild("sh", ["-c", `. ${m.etc}/model-plane.env; . "$HOME/.config/cmux/env"; printf '%s|%s' "$OPENAI_BASE_URL" "$OPENAI_API_KEY"`], { env: env(m) });
    expect(shell.stdout).toBe(`${OPENAI}|${USER_KEY}`);
  });

  test("is idempotent", async () => {
    const m = machine();
    writeFileSync(m.envFile, `export OPENAI_API_KEY='${USER_KEY}'\n`);
    await guard(m, "direct", "plane");
    const first = [readFileSync(m.envFile, "utf8"), readFileSync(m.codex, "utf8")];
    await guard(m, "direct", "plane");
    expect([readFileSync(m.envFile, "utf8"), readFileSync(m.codex, "utf8")]).toEqual(first);
    expect(readFileSync(m.codex, "utf8").match(/\[model_providers\.cmux-openai-key\]/g)).toHaveLength(1);
  });

  test("keeps a user's own endpoint, but replaces a CodeRouter endpoint beside the key", async () => {
    const own = machine();
    writeFileSync(own.envFile, `export OPENAI_API_KEY='${USER_KEY}'\nexport OPENAI_BASE_URL='https://proxy.example.test/v1'\n`);
    await guard(own, "direct", "plane");
    expect(envLine(own, "OPENAI_BASE_URL")).toBe("export OPENAI_BASE_URL='https://proxy.example.test/v1'");
    const plane = machine();
    writeFileSync(plane.envFile, `export OPENAI_API_KEY='${USER_KEY}'\nexport OPENAI_BASE_URL='${ORIGIN}/v1'\n`);
    await guard(plane, "direct", "plane");
    expect(envLine(plane, "OPENAI_BASE_URL")).toBe(`export OPENAI_BASE_URL='${OPENAI}'`);
  });

  test("an Anthropic key gets Anthropic's own endpoint over an older image's shell-wide CodeRouter one", async () => {
    const m = machine();
    writeFileSync(m.envFile, `export ANTHROPIC_API_KEY='sk-ant-user'\n`);
    await guard(m, "keep", "direct");
    expect(envLine(m, "ANTHROPIC_BASE_URL")).toBe("export ANTHROPIC_BASE_URL='https://api.anthropic.com'");
    expect(envLine(m, "OPENAI_BASE_URL")).toBeUndefined();
    const claudeConfig = JSON.parse(readFileSync(path.join(m.home, ".claude.json"), "utf8"));
    expect(claudeConfig.customApiKeyResponses.approved).toContain("sk-ant-user".slice(-20));
    // No OpenAI key: codex keeps CodeRouter.
    expect(readFileSync(m.codex, "utf8")).toContain('model_provider = "cmux"\n');
  });

  test("refreshes Claude's approval when a delivered key rotates", async () => {
    const m = machine();
    writeFileSync(path.join(m.home, ".claude.json"), JSON.stringify({
      hasCompletedOnboarding: true,
      customApiKeyResponses: { approved: ["old-key-suffix"], rejected: [] },
    }));
    writeFileSync(m.envFile, `export ANTHROPIC_API_KEY='sk-ant-rotated-key'\n`);
    await guard(m, "keep", "direct");
    const approved = JSON.parse(readFileSync(path.join(m.home, ".claude.json"), "utf8")).customApiKeyResponses.approved;
    expect(approved).toContain("sk-ant-rotated-key".slice(-20));
    expect(approved).toContain("old-key-suffix");
  });

  test("does not replace a malformed Claude config while refreshing approval", async () => {
    const m = machine();
    const configPath = path.join(m.home, ".claude.json");
    const malformed = "{\"hasCompletedOnboarding\": true,\n";
    writeFileSync(configPath, malformed);
    writeFileSync(m.envFile, "export ANTHROPIC_API_KEY='sk-ant-user'\n");

    await guard(m, "keep", "direct");

    expect(readFileSync(configPath, "utf8")).toBe(malformed);
  });

  test("does not replace a non-object Claude config while refreshing approval", async () => {
    const m = machine();
    const configPath = path.join(m.home, ".claude.json");
    const nonObject = "[\"preserve this state\"]\n";
    writeFileSync(configPath, nonObject);
    writeFileSync(m.envFile, "export ANTHROPIC_API_KEY='sk-ant-user'\n");

    await guard(m, "keep", "direct");

    expect(readFileSync(configPath, "utf8")).toBe(nonObject);
  });

  test("keep changes nothing; plane releases only what cmux added", async () => {
    const m = machine();
    writeFileSync(m.envFile, `export OPENAI_API_KEY='${USER_KEY}'\n`);
    await guard(m, "direct", "direct");
    await cmux(m, "env", "rm", "OPENAI_API_KEY", "ANTHROPIC_API_KEY");
    // The sync's protecting pass while keys are still being removed.
    await guard(m, "keep", "keep");
    expect(readFileSync(m.codex, "utf8")).toContain('model_provider = "cmux-openai-key"');
    await guard(m, "plane", "plane");
    expect(envLine(m, "OPENAI_BASE_URL")).toBeUndefined();
    expect(envLine(m, "ANTHROPIC_BASE_URL")).toBeUndefined();
    expect(readFileSync(m.codex, "utf8").split("\n")[0]).toBe('model_provider = "cmux"');
    // A user's own endpoint is never released.
    await cmux(m, "env", "set", "OPENAI_BASE_URL=https://proxy.example.test/v1");
    await guard(m, "plane", "plane");
    expect(envLine(m, "OPENAI_BASE_URL")).toBe("export OPENAI_BASE_URL='https://proxy.example.test/v1'");
  });

  test("plane never releases a provider whose key reached the env file outside Cloud Secrets", async () => {
    // `cmux vm env set OPENAI_API_KEY=…` (or `cmux env set` on the machine) put
    // the key there; a later vault sync for another provider asks for plane.
    const m = machine();
    writeFileSync(m.envFile, `export OPENAI_API_KEY='${USER_KEY}'\nexport ANTHROPIC_AUTH_TOKEN='${USER_KEY}'\n`);
    await guard(m, "direct", "direct");
    await guard(m, "plane", "plane");
    expect(envLine(m, "OPENAI_BASE_URL")).toBe("export OPENAI_BASE_URL='https://api.openai.com/v1'");
    expect(envLine(m, "ANTHROPIC_BASE_URL")).toBe("export ANTHROPIC_BASE_URL='https://api.anthropic.com'");
    expect(readFileSync(m.codex, "utf8")).toContain('model_provider = "cmux-openai-key"');
    expect(readFileSync(m.codex, "utf8")).not.toContain('model_provider = "cmux"\n');
    // Once the key is gone (a vault removal runs before the guard), plane releases.
    await cmux(m, "env", "rm", "OPENAI_API_KEY", "ANTHROPIC_AUTH_TOKEN");
    await guard(m, "plane", "plane");
    expect(envLine(m, "OPENAI_BASE_URL")).toBeUndefined();
    expect(envLine(m, "ANTHROPIC_BASE_URL")).toBeUndefined();
  });

  test("codex with the user's own OpenAI endpoint uses that endpoint, never api.openai.com or CodeRouter", async () => {
    const m = machine();
    const PROXY = "https://proxy.example.test/v1";
    const block = (url: string) => `[model_providers.cmux-openai-key]\nname = "OpenAI"\nbase_url = "${url}"\nenv_key = "OPENAI_API_KEY"`;
    // The Mac's sync: the protecting pass, the key and endpoint over the link, then the full pass.
    await guard(m, "user", "keep");
    await cmux(m, "env", "set", `OPENAI_API_KEY=${USER_KEY}`, `OPENAI_BASE_URL=${PROXY}`);
    await guard(m, "user", "plane");
    expect(readFileSync(m.codex, "utf8")).toContain('model_provider = "cmux-openai-key"');
    expect(readFileSync(m.codex, "utf8")).toContain(block(PROXY));
    // A changed endpoint follows, in the one block.
    await cmux(m, "env", "set", "OPENAI_BASE_URL=https://other.example.test/v1");
    await guard(m, "user", "plane");
    expect(readFileSync(m.codex, "utf8")).toContain(block("https://other.example.test/v1"));
    expect(readFileSync(m.codex, "utf8").match(/\[model_providers\.cmux-openai-key\]/g)).toHaveLength(1);
    // The user drops their endpoint: back to OpenAI's own.
    await cmux(m, "env", "rm", "OPENAI_BASE_URL");
    await guard(m, "direct", "plane");
    expect(readFileSync(m.codex, "utf8")).toContain(block(OPENAI));
    // An endpoint on the model router never carries the user's key.
    await cmux(m, "env", "set", `OPENAI_BASE_URL=${ORIGIN}/v1`);
    await guard(m, "user", "plane");
    expect(readFileSync(m.codex, "utf8")).toContain(block(OPENAI));
  });

  test("leaves codex to a launcher that already applies the precedence per launch", async () => {
    const m = machine({ newLauncher: true });
    const before = readFileSync(m.codex, "utf8");
    await guard(m, "direct", "plane");
    expect(readFileSync(m.codex, "utf8")).toBe(before);
  });

  test("leaves a codex provider the user chose alone", async () => {
    const m = machine();
    writeFileSync(m.codex, 'model_provider = "mine"\n');
    await guard(m, "direct", "plane");
    expect(readFileSync(m.codex, "utf8")).toBe('model_provider = "mine"\n');
  });

  test("names the provider whose endpoint could not be written; the other provider stays deliverable", async () => {
    const m = machine();
    const shim = path.join(m.bin, "cmux-shim");
    writeFileSync(shim, GUEST_CMUX_SHIM);
    chmodSync(shim, 0o755);
    writeFileSync(path.join(m.bin, "cmux"), `#!/bin/sh\ncase "$*" in *ANTHROPIC_BASE_URL*) exit 1 ;; esac\nexec ${JSON.stringify(shim)} "$@"\n`);
    const result = await guard(m, "direct", "direct");
    expect(result.status).toBe(0);
    expect(result.openai).toBe("ok");
    expect(result.anthropic).toBe("env");
    expect(envLine(m, "OPENAI_BASE_URL")).toBe(`export OPENAI_BASE_URL='${OPENAI}'`);
  });
});

/** Starts <agent> the way a terminal on today's image does: baked plane, agent-config, the machine env, the launcher. */
async function launch(m: Machine, agent: Agent, prefix = "") {
  const result = await runChild(
    "/bin/bash",
    ["-c", `. ${m.etc}/model-plane.env; . ${m.etc}/agent-config.sh; [ -f "$HOME/.config/cmux/env" ] && . "$HOME/.config/cmux/env"; ${prefix} ${m.launchers[agent]} --resume x`],
    { env: env(m) },
  );
  expect(result.status).toBe(0);
  return Object.fromEntries(result.stdout.trim().split("\n").map((line) => [line.slice(0, line.indexOf("=")), line.slice(line.indexOf("=") + 1)]));
}

describe("today's image, guarded: a user's key reaches its provider, never CodeRouter", () => {
  const ANTHROPIC_KEY = "sk-ant-user-routing-key";

  test("a brand-new machine's first sync routes before the first shell, then every agent and SDK goes direct", async () => {
    const m = machine({ fresh: true });
    // The Mac's first sync: the guard (protecting only), then the key over the link.
    expect((await guard(m, "direct", "keep")).status).toBe(0);
    await cmux(m, "env", "set", `OPENAI_API_KEY=${USER_KEY}`);
    expect((await guard(m, "direct", "plane")).status).toBe(0);

    // codex: the config the first shell would have written exists, on the user's key provider.
    const codex = readFileSync(m.codex, "utf8");
    expect(codex).toContain('model_provider = "cmux-openai-key"');
    expect(codex).toContain(`base_url = "${ORIGIN}/v1"`);
    // OpenCode: fetched once with the placeholder; its providers carry the placeholder.
    const calls = readFileSync(m.calls, "utf8");
    expect(calls).toContain(`authorization: Bearer ${PLACEHOLDER}`);
    expect(calls).not.toContain(USER_KEY);
    const team = readFileSync(path.join(m.home, ".config/cmux/opencode-team.json"), "utf8");
    expect(JSON.parse(team).provider.go.options.apiKey).toBe(PLACEHOLDER);

    const sdk = await runChild("/bin/bash", ["-c", `. ${m.etc}/model-plane.env; . ${m.etc}/agent-config.sh; . "$HOME/.config/cmux/env"; bash -c '. ${m.etc}/agent-config.sh; printf "%s|%s" "$OPENAI_BASE_URL" "$OPENAI_API_KEY"'`], { env: env(m) });
    expect(sdk.stdout).toBe(`${OPENAI}|${USER_KEY}`);

    const codexEnv = await launch(m, "codex");
    expect(codexEnv.args).toBe("--resume x");
    expect(codexEnv.OPENAI_API_KEY).toBe(USER_KEY);
    expect(codexEnv.OPENAI_BASE_URL).toBe(OPENAI);

    const callsBefore = readFileSync(m.calls, "utf8");
    const opencodeEnv = await launch(m, "opencode");
    expect(opencodeEnv.OPENCODE_CONFIG).toBe(path.join(m.home, ".config/cmux/opencode-team.json"));
    // No second fetch, so no request carried the user's key.
    expect(readFileSync(m.calls, "utf8").replace(callsBefore, "")).not.toContain("opencode/config");
    expect(readFileSync(m.calls, "utf8")).not.toContain(USER_KEY);

    // Every write the image makes to the model-plane copy lands in /dev/null.
    expect(readlinkSync(m.planeCopy)).toBe("/dev/null");
  });

  for (const [why, failure] of [["does not resolve from exec", { FAKE_CATALOG_EXIT: "6" }], ["answers 503", { FAKE_CATALOG_STATUS: "503" }]] as const) {
    test(`an OpenCode catalog that ${why} never holds a key back, and OpenCode never fetches with the user's key`, async () => {
      const m = machine({ fresh: true });
      const result = await guard(m, "direct", "keep", failure);
      expect(result.status).toBe(0);
      expect(result.openai).toBe("ok");
      // A cmux stub stands in for the providers, so a team-mode launch has a
      // file and never fetches (the baked launcher fetches only when it is absent).
      const team = path.join(m.home, ".config/cmux/opencode-team.json");
      expect(JSON.parse(readFileSync(team, "utf8"))).toEqual({});
      await cmux(m, "env", "set", `OPENAI_API_KEY=${USER_KEY}`);
      mkdirSync(path.join(m.home, ".config/cmux/agent-auth"), { recursive: true });
      writeFileSync(path.join(m.home, ".config/cmux/agent-auth/opencode"), "team\n");
      const before = existsSync(m.calls) ? readFileSync(m.calls, "utf8") : "";
      const opencode = await launch(m, "opencode");
      expect(opencode.OPENCODE_CONFIG).toBe(team);
      const after = existsSync(m.calls) ? readFileSync(m.calls, "utf8") : "";
      expect(after.slice(before.length)).not.toContain("opencode/config");
      expect(after).not.toContain(USER_KEY);
      // A later sync that reaches the catalog replaces the stub with the real providers.
      rmSync(path.join(m.home, ".cache/cmux"), { recursive: true, force: true });
      expect((await guard(m, "direct", "keep")).openai).toBe("ok");
      expect(JSON.parse(readFileSync(team, "utf8")).provider.go.options.apiKey).toBe(PLACEHOLDER);
    });
  }

  test("a user's own OpenCode team file is never replaced by the stub", async () => {
    const m = machine({ fresh: true });
    const team = path.join(m.home, ".config/cmux/opencode-team.json");
    writeFileSync(team, '{"provider":{"mine":{}}}');
    await guard(m, "direct", "keep", { FAKE_CATALOG_EXIT: "6" });
    expect(readFileSync(team, "utf8")).toBe('{"provider":{"mine":{}}}');
  });

  test("a team with no OpenCode account, or a user who chose own mode, does not block the key", async () => {
    const none = machine({ fresh: true });
    expect((await guard(none, "direct", "keep", { FAKE_CATALOG_STATUS: "403" })).status).toBe(0);
    const own = machine({ fresh: true });
    mkdirSync(path.join(own.home, ".config/cmux/agent-auth"), { recursive: true });
    writeFileSync(path.join(own.home, ".config/cmux/agent-auth/opencode"), "own\n");
    expect((await guard(own, "direct", "keep", { FAKE_CATALOG_STATUS: "503" })).status).toBe(0);
  });

  test("Claude Code with the user's Anthropic key or bearer token never gets the CodeRouter pair", async () => {
    for (const [name, value] of [["ANTHROPIC_API_KEY", ANTHROPIC_KEY], ["ANTHROPIC_AUTH_TOKEN", "user-bearer-token"]]) {
      const m = machine();
      await guard(m, "keep", "direct");
      await cmux(m, "env", "set", `${name}=${value}`);
      const claude = await launch(m, "claude");
      expect(claude.ANTHROPIC_BASE_URL).toBe("https://api.anthropic.com");
      expect(claude[name]).toBe(value);
      expect(claude.ANTHROPIC_API_KEY).not.toBe(PLACEHOLDER);
    }
  });

  test("codex own mode with a codex login uses the user's key with OpenAI (never CodeRouter)", async () => {
    const m = machine();
    mkdirSync(path.join(m.home, ".config/cmux/agent-auth"), { recursive: true });
    writeFileSync(path.join(m.home, ".config/cmux/agent-auth/codex"), "own\n");
    writeFileSync(path.join(m.home, ".codex/auth.json"), JSON.stringify({ tokens: { access_token: "at" } }));
    await guard(m, "direct", "plane");
    await cmux(m, "env", "set", `OPENAI_API_KEY=${USER_KEY}`);
    const codexEnv = await launch(m, "codex");
    // Today's launcher overrides only a provider named "cmux"; the config names
    // the user's key provider, at OpenAI.
    expect(codexEnv.args).toBe("--resume x");
    expect(readFileSync(m.codex, "utf8")).toContain(`[model_providers.cmux-openai-key]\nname = "OpenAI"\nbase_url = "${OPENAI}"`);
  });
});

describe("machine env provider endpoints (cmux env set/rm on new images)", () => {
  test("a user's key gets its provider's endpoint; the placeholder does not; the endpoint goes with the key", async () => {
    const m = machine();
    await cmux(m, "env", "set", `OPENAI_API_KEY=${USER_KEY}`, "ANTHROPIC_AUTH_TOKEN=user-bearer", "OTHER=1");
    expect(envLine(m, "OPENAI_BASE_URL")).toBe(`export OPENAI_BASE_URL='${OPENAI}'`);
    expect(envLine(m, "ANTHROPIC_BASE_URL")).toBe("export ANTHROPIC_BASE_URL='https://api.anthropic.com'");
    await cmux(m, "env", "rm", "OPENAI_API_KEY");
    expect(envLine(m, "OPENAI_BASE_URL")).toBeUndefined();
    expect(envLine(m, "ANTHROPIC_BASE_URL")).toBeDefined();
    await cmux(m, "env", "set", `OPENAI_API_KEY=${PLACEHOLDER}`);
    expect(envLine(m, "OPENAI_BASE_URL")).toBeUndefined();
  });

  test("a user's own endpoint wins and survives removing the key", async () => {
    const m = machine();
    await cmux(m, "env", "set", "OPENAI_BASE_URL=https://proxy.example.test/v1", `OPENAI_API_KEY=${USER_KEY}`);
    expect(envLine(m, "OPENAI_BASE_URL")).toBe("export OPENAI_BASE_URL='https://proxy.example.test/v1'");
    await cmux(m, "env", "rm", "OPENAI_API_KEY");
    expect(envLine(m, "OPENAI_BASE_URL")).toBe("export OPENAI_BASE_URL='https://proxy.example.test/v1'");
  });

  test("a set never drops the endpoint the Mac's guard added before the key arrives", async () => {
    const m = machine();
    await guard(m, "direct", "keep");
    expect(envLine(m, "OPENAI_BASE_URL")).toBe(`export OPENAI_BASE_URL='${OPENAI}'`);
    await cmux(m, "env", "set", "OTHER=1");
    expect(envLine(m, "OPENAI_BASE_URL")).toBe(`export OPENAI_BASE_URL='${OPENAI}'`);
  });

  test("a user's own endpoint equal to the provider default survives removing the key", async () => {
    const m = machine();
    await cmux(m, "env", "set", `OPENAI_BASE_URL=${OPENAI}`, `OPENAI_API_KEY=${USER_KEY}`);
    await cmux(m, "env", "rm", "OPENAI_API_KEY");
    expect(envLine(m, "OPENAI_BASE_URL")).toBe(`export OPENAI_BASE_URL='${OPENAI}'`);
    // Setting it explicitly after the shim added it makes it the user's too.
    const later = machine();
    await cmux(later, "env", "set", `OPENAI_API_KEY=${USER_KEY}`);
    await cmux(later, "env", "set", `OPENAI_BASE_URL=${OPENAI}`);
    await cmux(later, "env", "rm", "OPENAI_API_KEY");
    expect(envLine(later, "OPENAI_BASE_URL")).toBe(`export OPENAI_BASE_URL='${OPENAI}'`);
    // The routes file names endpoints only, never a value.
    expect(readFileSync(`${later.envFile}.routes`, "utf8")).not.toContain("sk-");
  });

  test("an empty key is no key: no provider endpoint is added for it", async () => {
    const m = machine();
    await cmux(m, "env", "set", "OPENAI_API_KEY=", "ANTHROPIC_API_KEY=");
    expect(envLine(m, "OPENAI_API_KEY")).toBe("export OPENAI_API_KEY=''");
    expect(envLine(m, "OPENAI_BASE_URL")).toBeUndefined();
    expect(envLine(m, "ANTHROPIC_BASE_URL")).toBeUndefined();
  });

  test("an env file written before the routes file still loses the endpoint its shim added", async () => {
    const m = machine();
    writeFileSync(m.envFile, `export OPENAI_API_KEY='${USER_KEY}'\nexport OPENAI_BASE_URL='${OPENAI}'\n`);
    await cmux(m, "env", "set", "OTHER=1");
    await cmux(m, "env", "rm", "OPENAI_API_KEY");
    expect(envLine(m, "OPENAI_BASE_URL")).toBeUndefined();
    expect(envLine(m, "OTHER")).toBe("export OTHER='1'");
  });
});
