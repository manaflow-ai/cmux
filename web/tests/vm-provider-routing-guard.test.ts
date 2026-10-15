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
// bytes against a machine shaped like an older image.

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

type Machine = { root: string; home: string; etc: string; bin: string; envFile: string; planeCopy: string; codex: string };

/** A machine from an image older than the precedence: baked plane, an older agent-config, the adapter as `cmux`. */
function machine(options: { newLauncher?: boolean } = {}): Machine {
  const root = mkdtempSync(path.join(tmpdir(), "cmux-routing-guard-"));
  roots.push(root);
  const home = path.join(root, "home");
  const etc = path.join(root, "etc");
  const bin = path.join(root, "bin");
  for (const dir of [home, etc, bin, path.join(home, ".config/cmux"), path.join(home, ".codex")]) mkdirSync(dir, { recursive: true });
  writeFileSync(path.join(etc, "model-plane.env"), renderVmGuestModelPlaneEnvFile(vmGuestModelPlaneEnv(ALIAS)));
  // The older agent-config's OpenCode fetch authenticates with OPENAI_API_KEY;
  // this stand-in records the key it would send.
  writeFileSync(
    path.join(etc, "agent-config.sh"),
    [
      "cmux_ensure_opencode_config() {",
      '  # key = os.environ["OPENAI_API_KEY"]',
      `  printf '%s %s\\n' "$OPENAI_API_KEY" "$CMUX_CODEROUTER_URL" > ${JSON.stringify(path.join(root, "opencode-fetch"))}`,
      "}",
      "",
    ].join("\n"),
  );
  writeFileSync(path.join(etc, "agent-auth.sh"), options.newLauncher ? "cmux_codex_user_key_provider=cmux-openai-key\n" : "# 2026-10-13 launcher\n");
  writeFileSync(path.join(bin, "cmux"), GUEST_CMUX_SHIM);
  chmodSync(path.join(bin, "cmux"), 0o755);
  const codex = path.join(home, ".codex/config.toml");
  writeFileSync(codex, `model_provider = "cmux"\n\n[model_providers.cmux]\nname = "cmux"\nbase_url = "${ORIGIN}/v1"\nenv_key = "OPENAI_API_KEY"\n`);
  return {
    root, home, etc, bin, codex,
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
async function guard(m: Machine, openai: string, anthropic: string) {
  const result = await runChild("sh", ["-c", GUARD, "cmux-provider-routing", openai, anthropic], { env: env(m) });
  expect(result.stdout).toBe("");
  return result;
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
    // The older OpenCode fetch already ran, with the placeholder.
    expect(readFileSync(path.join(m.root, "opencode-fetch"), "utf8")).toBe(`${PLACEHOLDER} ${ORIGIN}\n`);
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
    // No OpenAI key: codex keeps CodeRouter.
    expect(readFileSync(m.codex, "utf8")).toContain('model_provider = "cmux"\n');
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

  test("fails loudly when the machine env cannot be written, so the Mac keeps the key off the machine", async () => {
    const m = machine();
    writeFileSync(path.join(m.bin, "cmux"), "#!/bin/sh\nexit 1\n");
    expect((await guard(m, "direct", "plane")).status).not.toBe(0);
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
});
