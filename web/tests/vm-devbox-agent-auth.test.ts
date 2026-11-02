import { afterEach, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { GUEST_CMUX_SHIM } from "../services/vms/guestCli";
import { VM_PLACEHOLDER_API_KEY } from "../services/coderouter/vmGuestEnv";
import { resolveVmGuestKind } from "../services/vms/vmKind";
import { runChild, runChildOk } from "./helpers/run-child";

// Each coding agent on a Cloud machine signs in one of two ways: the team's
// CodeRouter accounts, or the user's own sign-in (Claude Code /login, codex
// login, opencode auth login). These tests pin the precedence: the agent
// launchers add CodeRouter configuration only in team mode, own mode sends
// nothing (and no own credential) to CodeRouter, and `cr use` records the
// choice the launchers read.

const templateDir = path.join(import.meta.dirname, "../services/vms/images/devbox");
const ORIGIN = "https://coderouter.cmux.test";
const PLACEHOLDER = "cmux-vm-edge-placeholder";
const AGENTS = ["claude", "codex", "opencode"] as const;
type Agent = (typeof AGENTS)[number];

/** A GET /api/coderouter/agent-access answer. */
const access = (claude: boolean, codex: boolean, opencode: boolean) =>
  JSON.stringify({ teamId: "t", agents: { claude, codex, opencode } });
const ALL = access(true, true, true);
const NONE = access(false, false, false);
const OPENCODE_CATALOG = JSON.stringify({
  provider: { go: { options: { baseURL: `${ORIGIN}/api/coderouter/opencode/proxy/go`, apiKey: PLACEHOLDER } } },
});

// Each test starts several real shells and launchers.
setDefaultTimeout(30_000);

const roots: string[] = [];
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

type Machine = { root: string; home: string; bin: string; calls: string; auth: string; config: string; kind: string; modelPlane: string; launchers: Record<Agent, string> };

/**
 * A HOME; for each agent a fake executable that prints the env and arguments
 * it was started with, and the image launcher pointed at it; and a fake
 * `curl` that answers the account check from $FAKE_ACCESS and the OpenCode
 * catalog (exit 7 when the answer is unset), logging every call.
 */
function machine(homeName = "home"): Machine {
  const root = mkdtempSync(path.join(tmpdir(), "cmux-agent-auth-"));
  roots.push(root);
  const home = path.join(root, homeName);
  const bin = path.join(root, "bin");
  mkdirSync(home, { recursive: true });
  mkdirSync(bin, { recursive: true });
  const calls = path.join(root, "curl.calls");
  const kind = path.join(root, "vm-kind");
  writeFileSync(kind, "owner\n");
  const auth = path.join(root, "agent-auth.sh");
  writeFileSync(auth, readFileSync(path.join(templateDir, "agent-auth.sh"), "utf8")
    .replaceAll("/etc/cmux/vm-kind", kind)
    .replaceAll("/etc/cmux/claude-onboarding.py", path.join(templateDir, "claude-onboarding.py")));
  const modelPlane = path.join(root, "model-plane.env");
  writeFileSync(modelPlane, `export CMUX_CODEROUTER_URL='${ORIGIN}'\nexport OPENAI_BASE_URL='${ORIGIN}/v1'\nexport OPENAI_API_KEY='${PLACEHOLDER}'\nexport ANTHROPIC_BASE_URL='${ORIGIN}'\nexport ANTHROPIC_API_KEY='${PLACEHOLDER}'\n`);
  const config = path.join(root, "agent-config.sh");
  writeFileSync(
    config,
    readFileSync(path.join(templateDir, "agent-config.sh"), "utf8")
      .replaceAll("/etc/cmux/vm-kind", kind)
      .replaceAll("/etc/cmux/claude-onboarding.py", path.join(templateDir, "claude-onboarding.py"))
      .replaceAll("/etc/cmux/model-plane.env", modelPlane),
  );
  writeFileSync(
    path.join(bin, "curl"),
    [
      "#!/bin/sh",
      `printf '%s\\n' "$*" >> ${JSON.stringify(calls)}`,
      'case "$*" in',
      '  */api/vm/reflection/kind*) printf \'{"kind":"%s"}\' "${FAKE_VM_KIND:-team}" ;;',
      // The catalog fetch asks for the status line (curl -w '\n%{http_code}').
      `  */opencode/config*) printf '%s\\n200' ${JSON.stringify(OPENCODE_CATALOG)} ;;`,
      // No answer is an HTTP error (curl -f: 22) unless a test names another exit.
      '  *) [ -n "${FAKE_ACCESS-}" ] || exit "${FAKE_CURL_EXIT:-22}"; printf \'%s\' "$FAKE_ACCESS" ;;',
      "esac",
      "",
    ].join("\n"),
  );
  chmodSync(path.join(bin, "curl"), 0o755);
  const launchers = {} as Record<Agent, string>;
  for (const agent of AGENTS) {
    const real = path.join(root, `${agent}-real`);
    writeFileSync(
      real,
      [
        "#!/bin/sh",
        ...["ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_CUSTOM_HEADERS", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CONFIG_DIR", "OPENAI_BASE_URL", "OPENAI_API_KEY", "CODEX_HOME", "OPENCODE_CONFIG", "OPENCODE_CONFIG_DIR", "XDG_DATA_HOME", "XDG_CONFIG_HOME"]
          .map((name) => `printf "${name}=%s\\n" "\${${name}-<unset>}"`),
        'printf "args=%s\\n" "$*"',
        "",
      ].join("\n"),
    );
    const launcher = path.join(root, agent);
    writeFileSync(
      launcher,
      readFileSync(path.join(templateDir, `cmux-${agent}`), "utf8")
        .replaceAll("/etc/cmux/agent-config.sh", config)
        .replaceAll("/etc/cmux/agent-auth.sh", auth)
        .replaceAll(`/usr/local/libexec/cmux-${agent}-real`, real),
    );
    chmodSync(real, 0o755);
    chmodSync(launcher, 0o755);
    launchers[agent] = launcher;
  }
  return { root, home, bin, calls, auth, config, kind, modelPlane, launchers };
}

/** The env a login shell on the machine starts from: the baked model plane. */
function bootEnv(m: Machine, extra: Record<string, string> = {}): Record<string, string> {
  return {
    PATH: `${m.bin}:${process.env.PATH ?? "/usr/bin:/bin"}`,
    HOME: m.home,
    LANG: "en_US.UTF-8",
    OPENAI_BASE_URL: `${ORIGIN}/v1`,
    OPENAI_API_KEY: PLACEHOLDER,
    CMUX_CODEROUTER_URL: ORIGIN,
    ANTHROPIC_BASE_URL: ORIGIN,
    ANTHROPIC_API_KEY: PLACEHOLDER,
    ...extra,
  };
}

function parse(stdout: string): Record<string, string> {
  return Object.fromEntries(stdout.trim().split("\n").map((line) => [line.slice(0, line.indexOf("=")), line.slice(line.indexOf("=") + 1)]));
}

/** Starts <agent> from a shell that sourced agent-config.sh, the way every terminal does. */
async function launch(m: Machine, agent: Agent, extra: Record<string, string> = {}, shellPrefix = "") {
  const result = await runChild(
    "/bin/bash",
    ["-c", `. ${m.config}; ${shellPrefix} ${m.launchers[agent]} --resume x`],
    { env: bootEnv(m, extra) },
  );
  expect(result.stderr).toBe("");
  expect(result.status).toBe(0);
  return parse(result.stdout);
}

function choose(m: Machine, mode: string, agent: Agent = "claude"): void {
  mkdirSync(path.join(m.home, ".config/cmux/agent-auth"), { recursive: true });
  writeFileSync(path.join(m.home, ".config/cmux/agent-auth", agent), `${mode}\n`);
}

/** The agent's own sign-in, as its login command leaves it on disk. */
function signIn(m: Machine, agent: Agent = "claude"): void {
  const files: Record<Agent, [string, unknown]> = {
    claude: [".claude/.credentials.json", { claudeAiOauth: { accessToken: "x" } }],
    codex: [".codex/auth.json", { OPENAI_API_KEY: null, tokens: { id_token: "e30.e30.sig", access_token: "at", refresh_token: "rt" } }],
    opencode: [".local/share/opencode/auth.json", { anthropic: { type: "api", key: "sk-ant-user" } }],
  };
  const [file, content] = files[agent];
  mkdirSync(path.dirname(path.join(m.home, file)), { recursive: true });
  writeFileSync(path.join(m.home, file), JSON.stringify(content));
}

/** agent-config.sh with its launcher directory pointed at this machine's launchers. */
function routedAgentConfig(m: Machine): string {
  const file = path.join(m.root, "agent-config.sh");
  writeFileSync(file, readFileSync(m.config, "utf8").replaceAll('"/etc/cmux/$cmux_ar_agent"', `"${m.root}/$cmux_ar_agent"`));
  return file;
}

/** The codex config agent-config.sh generates: CodeRouter as the provider. */
function cmuxCodexConfig(m: Machine, provider = "cmux"): void {
  mkdirSync(path.join(m.home, ".codex"), { recursive: true });
  writeFileSync(path.join(m.home, ".codex/config.toml"), `model_provider = "${provider}"\n\n[model_providers.cmux]\nname = "cmux"\nbase_url = "${ORIGIN}/v1"\nenv_key = "OPENAI_API_KEY"\n`);
}

describe("agent-auth.sh", () => {
  test("sends only the placeholder the TypeScript side defines", () => {
    expect(readFileSync(path.join(templateDir, "agent-auth.sh"), "utf8")).toContain(`cmux_aa_placeholder=${VM_PLACEHOLDER_API_KEY}\n`);
    expect(PLACEHOLDER).toBe(VM_PLACEHOLDER_API_KEY);
  });
});

describe("Claude Code sign-in precedence", () => {
  test("a shell never exports the CodeRouter pair, and still persists it for the launcher", async () => {
    const m = machine();
    const probe = `printf '%s|%s|%s|%s' "\${ANTHROPIC_BASE_URL-unset}" "\${ANTHROPIC_API_KEY-unset}" "\${CMUX_CLAUDE_TEAM_BASE_URL-}" "\${CMUX_CLAUDE_TEAM_API_KEY-}"`;
    const first = await runChild("/bin/bash", ["-c", `. ${m.config}; ${probe}`], { env: bootEnv(m) });
    expect(first.stdout).toBe(`unset|unset|${ORIGIN}|${PLACEHOLDER}`);
    // A nested shell inherits only the set-aside pair; it re-persists the
    // model-plane names and keeps the pair out of its own env too.
    const nested = await runChild(
      "/bin/bash",
      ["-c", `. ${m.config}; bash -c '. ${m.config}; ${probe.replaceAll("'", "'\\''")}'`],
      { env: bootEnv(m) },
    );
    expect(nested.stdout).toBe(`unset|unset|${ORIGIN}|${PLACEHOLDER}`);
    const plane = readFileSync(path.join(m.home, ".config/cmux/model-plane.env"), "utf8");
    expect(plane).toContain(`export ANTHROPIC_BASE_URL='${ORIGIN}'`);
    expect(plane).toContain(`export ANTHROPIC_API_KEY='${PLACEHOLDER}'`);
    // The first-run seed still pre-approves the placeholder for team mode.
    const seed = JSON.parse(readFileSync(path.join(m.home, ".claude.json"), "utf8"));
    expect(seed.customApiKeyResponses.approved).toEqual([PLACEHOLDER.slice(-20)]);
  });

  test("a user-set Anthropic endpoint or key is never moved or replaced", async () => {
    const m = machine();
    const probe = `printf '%s|%s' "\${ANTHROPIC_BASE_URL-unset}" "\${ANTHROPIC_API_KEY-unset}"`;
    const own = await runChild("/bin/bash", ["-c", `. ${m.config}; ${probe}`], {
      env: bootEnv(m, { ANTHROPIC_BASE_URL: "https://api.example.test", ANTHROPIC_API_KEY: "sk-ant-user" }),
    });
    expect(own.stdout).toBe("https://api.example.test|sk-ant-user");
    // A key the user exported after the pair was set aside survives a nested shell.
    const nested = await runChild(
      "/bin/bash",
      ["-c", `. ${m.config}; export ANTHROPIC_API_KEY=sk-ant-user; bash -c '. ${m.config}; ${probe.replaceAll("'", "'\\''")}'`],
      { env: bootEnv(m) },
    );
    expect(nested.stdout).toBe("unset|sk-ant-user");
  });

  test("own mode starts claude with no CodeRouter env, so its /login is what it uses", async () => {
    const m = machine();
    choose(m, "own");
    const env = await launch(m, "claude", { CMUX_WORKSPACE_ID: "ws-1", CMUX_SURFACE_ID: "sf-1" });
    expect(env.ANTHROPIC_BASE_URL).toBe("<unset>");
    expect(env.ANTHROPIC_API_KEY).toBe("<unset>");
    expect(env.ANTHROPIC_CUSTOM_HEADERS).toBe("<unset>");
    expect(env.args).toBe("--resume x");
    // An explicit choice needs no account check.
    expect(existsSync(m.calls)).toBe(false);
  });

  test("own mode also drops the pair a shell from an older agent-config still exports", async () => {
    const m = machine();
    choose(m, "own");
    const env = await launch(m, "claude", {}, `export ANTHROPIC_BASE_URL=${ORIGIN} ANTHROPIC_API_KEY=${PLACEHOLDER};`);
    expect(env.ANTHROPIC_BASE_URL).toBe("<unset>");
    expect(env.ANTHROPIC_API_KEY).toBe("<unset>");
  });

  test("team mode adds the CodeRouter pair and usage headers, even over an own login", async () => {
    const m = machine();
    choose(m, "team");
    signIn(m);
    const env = await launch(m, "claude", { CMUX_WORKSPACE_ID: "ws-1" });
    expect(env.ANTHROPIC_BASE_URL).toBe(ORIGIN);
    expect(env.ANTHROPIC_API_KEY).toBe(PLACEHOLDER);
    expect(env.ANTHROPIC_CUSTOM_HEADERS).toBe("x-cmux-workspace-id: ws-1");
  });

  test("a user-set key wins in every mode", async () => {
    for (const mode of ["team", "own"]) {
      const m = machine();
      choose(m, mode);
      const env = await launch(m, "claude", {}, "export ANTHROPIC_API_KEY=sk-ant-user;");
      expect(env.ANTHROPIC_API_KEY).toBe("sk-ant-user");
      expect(env.ANTHROPIC_BASE_URL).toBe("<unset>");
    }
  });

  test("a one-off user key is never persisted, so team mode keeps working afterwards", async () => {
    const m = machine();
    choose(m, "team");
    // `ANTHROPIC_API_KEY=... claude` once: the launcher sources agent-config.sh.
    const once = await launch(m, "claude", {}, "ANTHROPIC_API_KEY=sk-ant-oneoff");
    expect(once.ANTHROPIC_API_KEY).toBe("sk-ant-oneoff");
    const plane = readFileSync(path.join(m.home, ".config/cmux/model-plane.env"), "utf8");
    expect(plane).not.toContain("sk-ant-oneoff");
    expect(plane).toContain(`export ANTHROPIC_API_KEY='${PLACEHOLDER}'`);
    // A fresh shell without the boot env reads the persisted file only.
    const fresh = await runChild("/bin/bash", ["-c", `. ${m.config}; ${m.launchers.claude}`], {
      env: { PATH: `${m.bin}:${process.env.PATH ?? "/usr/bin:/bin"}`, HOME: m.home },
    });
    expect(parse(fresh.stdout).ANTHROPIC_API_KEY).toBe(PLACEHOLDER);
    expect(parse(fresh.stdout).ANTHROPIC_BASE_URL).toBe(ORIGIN);
  });
});

describe("Claude Code 2.1.299 onboarding", () => {
  // Verified against the pinned native package: CLAUDE_CONFIG_DIR changes
  // the global .claude.json path, not just settings/credentials. The gate
  // reads hasCompletedOnboarding from that document (see helper provenance).
  test("root and cmux team launches read a complete seed in the selected config home", async () => {
    expect(readFileSync(path.join(templateDir, "Dockerfile"), "utf8"))
      .toContain("ARG CMUX_IMAGE_CLAUDE_CODE_VERSION=2.1.299");
    for (const user of ["root", "cmux"]) {
      const m = machine(user);
      writeFileSync(m.kind, "team\n");
      const personal = JSON.stringify({ oauthAccount: { accountUuid: "personal" }, theme: "light" });
      writeFileSync(path.join(m.home, ".claude.json"), personal);
      const env = await launch(m, "claude", { FAKE_ACCESS: ALL });
      const selected = path.join(env.CLAUDE_CONFIG_DIR, ".claude.json");
      expect(JSON.parse(readFileSync(selected, "utf8"))).toEqual({
        hasCompletedOnboarding: true,
        bypassPermissionsModeAccepted: true,
        theme: "dark",
        projects: { "/": { hasTrustDialogAccepted: true } },
        customApiKeyResponses: { approved: [PLACEHOLDER.slice(-20)], rejected: [] },
      });
      expect(statSync(selected).mode & 0o777).toBe(0o600);
      expect(readFileSync(path.join(m.home, ".claude.json"), "utf8")).toBe(personal);
      // A later launch preserves existing state and preferences.
      const edited = { ...JSON.parse(readFileSync(selected, "utf8")), theme: "light", numStartups: 3 };
      writeFileSync(selected, JSON.stringify(edited));
      await launch(m, "claude", { FAKE_ACCESS: ALL });
      expect(JSON.parse(readFileSync(selected, "utf8"))).toEqual(edited);
    }
  });
});

describe("Codex sign-in precedence", () => {
  test("own mode starts codex on its built-in provider with no CodeRouter env, so codex login is what it uses", async () => {
    const m = machine();
    cmuxCodexConfig(m);
    choose(m, "own", "codex");
    const env = await launch(m, "codex");
    expect(env.args).toBe('-c model_provider="openai" --resume x');
    expect(env.OPENAI_BASE_URL).toBe("<unset>");
    expect(env.OPENAI_API_KEY).toBe("<unset>");
  });

  test("team mode keeps the CodeRouter provider and its key", async () => {
    const m = machine();
    cmuxCodexConfig(m);
    choose(m, "team", "codex");
    signIn(m, "codex");
    const env = await launch(m, "codex");
    expect(env.args).toBe("--resume x");
    expect(env.OPENAI_API_KEY).toBe(PLACEHOLDER);
  });

  test("shared team CODEX_HOME carries the baked file-hook trust state", async () => {
    const m = machine();
    mkdirSync(path.join(m.home, ".codex"), { recursive: true });
    writeFileSync(
      path.join(m.home, ".codex/config.toml"),
      [
        "[hooks.state.\"" + path.join(m.home, ".codex/hooks.json:pre_tool_use:0:0") + "\"]",
        'trusted_hash = "sha256:pre-tool"',
        "",
        "[hooks.state.\"/tmp/user-hooks.json:stop:0:0\"]",
        'trusted_hash = "sha256:user"',
        "",
      ].join("\n"),
    );
    writeFileSync(path.join(m.home, ".codex/hooks.json"), "{}\n");
    writeFileSync(m.kind, "team\n");
    choose(m, "team", "codex");
    await Promise.all([launch(m, "codex"), launch(m, "codex")]);
    const team = readFileSync(path.join(m.home, ".config/cmux/codex-team/config.toml"), "utf8");
    expect(() => Bun.TOML.parse(team)).not.toThrow();
    expect(team).toContain(`[hooks.state.\"${path.join(m.home, ".codex/hooks.json:pre_tool_use:0:0")}\"]`);
    expect(team).toContain('trusted_hash = "sha256:pre-tool"');
    expect(team).not.toContain("sha256:user");
  });

  test("a provider the user chose in config.toml is never overridden", async () => {
    const m = machine();
    cmuxCodexConfig(m, "mine");
    choose(m, "own", "codex");
    expect((await launch(m, "codex")).args).toBe("--resume x");
  });

  test("own mode keeps a user's own OpenAI endpoint and key", async () => {
    const m = machine();
    cmuxCodexConfig(m);
    choose(m, "own", "codex");
    const env = await launch(m, "codex", {}, "export OPENAI_BASE_URL=https://api.example.test/v1 OPENAI_API_KEY=sk-user;");
    expect(env.OPENAI_BASE_URL).toBe("https://api.example.test/v1");
    expect(env.OPENAI_API_KEY).toBe("sk-user");
  });

  test("with no choice, codex login counts as choosing own; an empty auth file does not", async () => {
    const m = machine();
    cmuxCodexConfig(m);
    signIn(m, "codex");
    expect((await launch(m, "codex", { FAKE_ACCESS: ALL })).args).toBe('-c model_provider="openai" --resume x');
    expect(existsSync(m.calls)).toBe(false);
    const empty = machine();
    cmuxCodexConfig(empty);
    mkdirSync(path.join(empty.home, ".codex"), { recursive: true });
    writeFileSync(path.join(empty.home, ".codex/auth.json"), '{"OPENAI_API_KEY":null,"tokens":null}');
    expect((await launch(empty, "codex", { FAKE_ACCESS: ALL })).args).toBe("--resume x");
  });

  test("an API-key login counts too", async () => {
    const m = machine();
    cmuxCodexConfig(m);
    mkdirSync(path.join(m.home, ".codex"), { recursive: true });
    writeFileSync(path.join(m.home, ".codex/auth.json"), '{"OPENAI_API_KEY":"sk-user"}');
    expect((await launch(m, "codex", { FAKE_ACCESS: ALL })).args).toBe('-c model_provider="openai" --resume x');
  });
});

// The trust-state labels of every Codex hook event `cmux-tui agent hook
// install codex` writes (CODEX_EVENTS in cmux-tui-hooks, 11 today), as Codex
// keys them: `<hooks.json>:<snake_case event>:0:0`. Read from the installer,
// so a new event is covered without editing this list.
const CODEX_HOOK_LABELS = (() => {
  const installer = readFileSync(path.join(import.meta.dirname, "../../cmux-tui/crates/cmux-tui-hooks/src/lib.rs"), "utf8");
  const events = /const CODEX_EVENTS: &\[&str\] = &\[([^\]]*)\];/.exec(installer)?.[1];
  if (!events) throw new Error("CODEX_EVENTS is gone from cmux-tui-hooks; point this test at its new home");
  return [...events.matchAll(/"([A-Za-z]+)"/g)].map(([, event]) => event.replace(/(?<!^)([A-Z])/g, "_$1").toLowerCase());
})();

describe("Codex hook trust in the shared team CODEX_HOME", () => {
  const codexTeam = (m: Machine) => path.join(m.home, ".config/cmux/codex-team");
  const defaultConfig = (m: Machine) => path.join(m.home, ".codex/config.toml");

  /** A team machine whose default ~/.codex holds cmux's hooks.json, as the bake leaves it. */
  function teamMachine(homeName?: string): Machine {
    const m = machine(homeName);
    mkdirSync(path.join(m.home, ".codex"), { recursive: true });
    writeFileSync(path.join(m.home, ".codex/hooks.json"), "{}\n");
    writeFileSync(m.kind, "team\n");
    return m;
  }

  /** The bake's trust entry for every cmux hook (hash `<tag>:<label>`), plus `extra` TOML; returns key -> hash. */
  function bakeTrust(m: Machine, tag: string, extra: string[] = []): Record<string, string> {
    const trusted = Object.fromEntries(
      CODEX_HOOK_LABELS.map((label) => [`${path.join(m.home, ".codex/hooks.json")}:${label}:0:0`, `${tag}:${label}`]),
    );
    const lines = Object.entries(trusted).flatMap(([key, hash]) => [`[hooks.state.${JSON.stringify(key)}]`, `trusted_hash = ${JSON.stringify(hash)}`, ""]);
    writeFileSync(defaultConfig(m), [...lines, ...extra].join("\n"));
    return trusted;
  }

  /** Replaces one baked entry's trusted_hash line in the default config with `line`. */
  function breakEntry(m: Machine, trusted: Record<string, string>, key: string, line: string): void {
    const text = readFileSync(defaultConfig(m), "utf8");
    const hashLine = `trusted_hash = ${JSON.stringify(trusted[key])}`;
    expect(text).toContain(hashLine);
    writeFileSync(defaultConfig(m), text.replace(hashLine, line));
  }

  /** A TOML file as a strict parser (Python's tomllib) reads it. */
  async function readToml(file: string): Promise<{ model_provider?: string; model_providers?: Record<string, Record<string, unknown>>; hooks?: { state?: Record<string, unknown> } }> {
    const result = await runChild("python3", ["-I", "-c", "import json, sys, tomllib; print(json.dumps(tomllib.load(open(sys.argv[1], 'rb'))))", file]);
    expect(result.stderr).toBe("");
    return JSON.parse(result.stdout);
  }

  /** Every key -> trusted_hash the team config holds, after checking its provider block is whole. */
  async function teamTrust(file: string): Promise<Record<string, unknown>> {
    const config = await readToml(file);
    expect(config.model_provider).toBe("cmux");
    expect(config.model_providers?.cmux).toEqual({
      name: "cmux",
      base_url: `${ORIGIN}/v1`,
      env_key: "OPENAI_API_KEY",
      wire_api: "responses",
      requires_openai_auth: false,
      supports_websockets: false,
    });
    return Object.fromEntries(Object.entries(config.hooks?.state ?? {}).map(([key, entry]) => [key, (entry as { trusted_hash?: unknown }).trusted_hash]));
  }

  /** A team codex launch whose stderr may carry the publish's log lines. */
  async function launchLogged(m: Machine) {
    const result = await runChild("/bin/bash", ["-c", `. ${m.config}; ${m.launchers.codex} --resume x`], { env: bootEnv(m) });
    expect(result.status).toBe(0);
    expect(parse(result.stdout).CODEX_HOME).toBe(codexTeam(m));
    return result.stderr;
  }

  test("every hook the default home trusts is trusted in the team home", async () => {
    // Codex app-server `hooks/list` is not on Linux CI; this checks the config
    // Codex reads that trust from, entry by entry.
    expect(CODEX_HOOK_LABELS.length).toBeGreaterThanOrEqual(11);
    const m = teamMachine();
    const trusted = bakeTrust(m, "sha256:baked", ['[hooks.state."/tmp/user-hooks.json:stop:0:0"]', 'trusted_hash = "sha256:user"', ""]);
    await launch(m, "codex");
    expect(await teamTrust(path.join(codexTeam(m), "config.toml"))).toEqual(trusted);
  });

  test("a reader during the publish sees the old config or the new one, whole, never a mix", async () => {
    const m = teamMachine();
    const target = path.join(codexTeam(m), "config.toml");
    const first = bakeTrust(m, "sha256:first");
    await launch(m, "codex");
    const old = readFileSync(target, "utf8");
    expect(await teamTrust(target)).toEqual(first);

    // Test-only seam in this machine's copy of agent-auth.sh: the publish
    // stops after the new config is fully written to its temporary file and
    // before it replaces the old one, until the test releases it. FIFOs make
    // the hand-off an event, not a timing guess.
    const paused = path.join(m.root, "publish.paused");
    const resume = path.join(m.root, "publish.resume");
    await runChildOk("mkfifo", [paused, resume]);
    const script = readFileSync(m.auth, "utf8");
    const publish = "    os.replace(temporary, target)\n";
    expect(script).toContain(publish);
    writeFileSync(m.auth, script.replace(publish, `    open(${JSON.stringify(paused)}, "w").close(); open(${JSON.stringify(resume)}).read()\n${publish}`));

    const second = bakeTrust(m, "sha256:second");
    // The launcher runs with the shell's result checked only after release,
    // so a failed assertion below cannot leave a rejected promise behind.
    const publishing = runChild("/bin/bash", ["-c", `. ${m.config}; ${m.launchers.codex} --resume x`], { env: bootEnv(m), timeout: 20_000 });
    try {
      // Opening the FIFO returns only once the publish holds its other end.
      expect((await runChild("cat", [paused], { timeout: 10_000 })).error).toBeUndefined();
      expect(readFileSync(target, "utf8")).toBe(old);
      expect(await teamTrust(target)).toEqual(first);
      // The new config is already complete beside it; only the rename is left.
      const pending = readdirSync(codexTeam(m)).filter((name) => name.startsWith(".config.toml."));
      expect(pending).toHaveLength(1);
      expect(await teamTrust(path.join(codexTeam(m), pending[0]))).toEqual(second);
    } finally {
      // Always release a paused publisher and wait for it, so it never
      // outlives the test or writes into a root afterEach removes. The
      // write-open waits for the publisher's read-open (no lost wake-up); if
      // the publisher never gets there, both runChild timeouts kill their
      // process groups well inside the test's 30 s.
      await runChild("sh", ["-c", ': > "$1"', "sh", resume], { timeout: 10_000 });
      await publishing;
    }
    const published = await publishing;
    expect(published.stderr).toBe("");
    expect(published.status).toBe(0);
    expect(await teamTrust(target)).toEqual(second);
    expect(readdirSync(codexTeam(m)).filter((name) => name.startsWith(".config.toml."))).toEqual([]);
  });

  test("a HOME with non-ASCII and non-BMP names keeps every trust entry", async () => {
    const m = teamMachine("hömé-日本語-🚀");
    const trusted = bakeTrust(m, "sha256:ünï", ['[hooks.state."/tmp/ユーザー/hööks-🚀.json:stop:0:0"]', 'trusted_hash = "sha256:user"', ""]);
    await launch(m, "codex");
    const target = path.join(codexTeam(m), "config.toml");
    expect(readFileSync(target, "utf8")).toContain(`[hooks.state."${path.join(m.home, ".codex/hooks.json")}:stop:0:0"]`);
    expect(await teamTrust(target)).toEqual(trusted);
  });

  test("a default-home config that is not TOML keeps the published trust, says so, and still starts codex", async () => {
    const m = teamMachine();
    const target = path.join(codexTeam(m), "config.toml");
    const trusted = bakeTrust(m, "sha256:baked");
    await launch(m, "codex");
    writeFileSync(defaultConfig(m), 'model = "unterminated\n[hooks.state\n');
    const log = await launchLogged(m);
    expect(log).toContain(`cannot read Codex hook trust from ${defaultConfig(m)}`);
    expect(await teamTrust(target)).toEqual(trusted);
  });

  test("an entry without a usable trusted_hash is skipped with a log line, and the others still copy", async () => {
    const m = teamMachine();
    const trusted = bakeTrust(m, "sha256:baked");
    const [missing, wrongType] = Object.keys(trusted);
    breakEntry(m, trusted, missing, "enabled = true");
    breakEntry(m, trusted, wrongType, "trusted_hash = 7");
    const log = await launchLogged(m);
    expect(log).toContain(`skipping Codex hook trust entry ${JSON.stringify(missing)}`);
    expect(log).toContain(`skipping Codex hook trust entry ${JSON.stringify(wrongType)}`);
    expect(await teamTrust(path.join(codexTeam(m), "config.toml"))).toEqual(
      Object.fromEntries(Object.entries(trusted).filter(([key]) => key !== missing && key !== wrongType)),
    );
  });

  test("a hook whose approval the default home revoked is no longer trusted in the team home", async () => {
    // Codex keeps a hook's state entry but drops its trusted_hash when the
    // user revokes approval; the team home must follow, not keep the old hash.
    const m = teamMachine();
    const trusted = bakeTrust(m, "sha256:baked");
    await launch(m, "codex");
    expect(await teamTrust(path.join(codexTeam(m), "config.toml"))).toEqual(trusted);
    const [revoked] = Object.keys(trusted);
    breakEntry(m, trusted, revoked, "enabled = true");
    expect(await launchLogged(m)).toContain(`skipping Codex hook trust entry ${JSON.stringify(revoked)}`);
    expect(await teamTrust(path.join(codexTeam(m), "config.toml"))).toEqual(
      Object.fromEntries(Object.entries(trusted).filter(([key]) => key !== revoked)),
    );
  });
});

describe("OpenCode sign-in precedence", () => {
  test("team mode layers the CodeRouter providers on for this launch, never in opencode's own config", async () => {
    const m = machine();
    choose(m, "team", "opencode");
    const env = await launch(m, "opencode");
    const team = path.join(m.home, ".config/cmux/opencode-team.json");
    expect(env.OPENCODE_CONFIG).toBe(team);
    expect(JSON.parse(readFileSync(team, "utf8")).provider.go.options.apiKey).toBe("{env:OPENAI_API_KEY}");
    expect(existsSync(path.join(m.home, ".config/opencode/opencode.json"))).toBe(false);
    // The team providers read the placeholder from OPENAI_API_KEY and carry
    // their own CodeRouter baseURL; the shell's CodeRouter endpoints are
    // dropped so an `opencode auth login` provider still reaches its own service.
    expect(env.OPENAI_API_KEY).toBe(PLACEHOLDER);
    expect(env.OPENAI_BASE_URL).toBe("<unset>");
    expect(env.ANTHROPIC_BASE_URL).toBe("<unset>");
  });

  test("a user's own OpenAI endpoint survives team mode", async () => {
    const m = machine();
    choose(m, "team", "opencode");
    const env = await launch(m, "opencode", {}, "export OPENAI_BASE_URL=https://api.example.test/v1;");
    expect(env.OPENAI_BASE_URL).toBe("https://api.example.test/v1");
  });

  test("own mode adds no providers and drops every CodeRouter endpoint, so own keys never reach it", async () => {
    // opencode sends an `opencode auth login` key to whatever
    // OPENAI_BASE_URL/ANTHROPIC_BASE_URL name.
    const m = machine();
    choose(m, "own", "opencode");
    const env = await launch(m, "opencode", {}, `export ANTHROPIC_BASE_URL=${ORIGIN} ANTHROPIC_API_KEY=${PLACEHOLDER};`);
    expect(env.OPENCODE_CONFIG).toBe("<unset>");
    expect(env.OPENAI_BASE_URL).toBe("<unset>");
    expect(env.OPENAI_API_KEY).toBe("<unset>");
    expect(env.ANTHROPIC_BASE_URL).toBe("<unset>");
    expect(env.ANTHROPIC_API_KEY).toBe("<unset>");
    // No catalog fetch either.
    expect(existsSync(m.calls)).toBe(false);
    expect(existsSync(path.join(m.home, ".config/cmux/opencode-team.json"))).toBe(false);
  });

  test("with no choice, opencode auth login counts as choosing own", async () => {
    const m = machine();
    signIn(m, "opencode");
    expect((await launch(m, "opencode", { FAKE_ACCESS: ALL })).OPENCODE_CONFIG).toBe("<unset>");
  });

  test("an OPENCODE_CONFIG the caller set wins in team mode", async () => {
    const m = machine();
    choose(m, "team", "opencode");
    expect((await launch(m, "opencode", { OPENCODE_CONFIG: "/tmp/mine.json" })).OPENCODE_CONFIG).toBe("/tmp/mine.json");
  });
});

describe("the default for every agent", () => {
  test("with no choice and no sign-in, the team's accounts for that agent decide", async () => {
    const m = machine();
    cmuxCodexConfig(m);
    const answer = access(true, false, true);
    expect((await launch(m, "claude", { FAKE_ACCESS: answer })).ANTHROPIC_API_KEY).toBe(PLACEHOLDER);
    expect((await launch(m, "codex", { FAKE_ACCESS: answer })).args).toBe('-c model_provider="openai" --resume x');
    expect((await launch(m, "opencode", { FAKE_ACCESS: answer })).OPENCODE_CONFIG).toBe(path.join(m.home, ".config/cmux/opencode-team.json"));
    // One account check answered all three (the answer is reused for a minute).
    const calls = readFileSync(m.calls, "utf8").trim().split("\n").filter((call) => call.includes("agent-access"));
    expect(calls).toHaveLength(1);
    expect(calls[0]).toContain(`${ORIGIN}/api/coderouter/agent-access`);
    expect(calls[0]).toContain(`authorization: Bearer ${PLACEHOLDER}`);
  });

  test("no account means the agent's own sign-in instead of a CodeRouter refusal", async () => {
    const m = machine();
    cmuxCodexConfig(m);
    expect((await launch(m, "claude", { FAKE_ACCESS: NONE })).ANTHROPIC_API_KEY).toBe("<unset>");
    expect((await launch(m, "codex", { FAKE_ACCESS: NONE })).args).toBe('-c model_provider="openai" --resume x');
    expect((await launch(m, "opencode", { FAKE_ACCESS: NONE })).OPENCODE_CONFIG).toBe("<unset>");
  });

  test("no answer keeps the long-standing default (team)", async () => {
    for (const answer of [undefined, "<html>", JSON.stringify({ error: "not_found" })]) {
      const m = machine();
      cmuxCodexConfig(m);
      const extra: Record<string, string> = answer === undefined ? {} : { FAKE_ACCESS: answer };
      expect((await launch(m, "claude", extra)).ANTHROPIC_API_KEY).toBe(PLACEHOLDER);
      expect((await launch(m, "codex", extra)).args).toBe("--resume x");
    }
  });

  test("CodeRouter unreachable from the machine means the agent's own sign-in", async () => {
    // Team mode cannot work when the CodeRouter address does not resolve (6)
    // or connect (7); a dev environment without the edge is one such machine.
    for (const exit of ["6", "7"]) {
      const m = machine();
      cmuxCodexConfig(m);
      expect((await launch(m, "claude", { FAKE_CURL_EXIT: exit })).ANTHROPIC_API_KEY).toBe("<unset>");
      expect((await launch(m, "codex", { FAKE_CURL_EXIT: exit })).args).toBe('-c model_provider="openai" --resume x');
      expect((await launch(m, "opencode", { FAKE_CURL_EXIT: exit })).OPENCODE_CONFIG).toBe("<unset>");
    }
  });

  test("a machine with no CodeRouter origin starts claude on its own sign-in, never an empty team plane", async () => {
    // fs-firstsend-exercise (2026-10-31): a shell with only the OpenAI pair persisted that pair alone,
    // so no shell after it had an origin, and team-unknown left claude with no endpoint and no key
    // ("Not logged in"). With no origin there is no team plane to choose.
    const m = machine();
    const env = bootEnv(m);
    for (const name of ["CMUX_CODEROUTER_URL", "ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY"]) delete env[name];
    const result = await runChild("/bin/bash", ["-c", `. ${m.config}; ${m.launchers.claude} --resume x`], { env });
    expect(result.status).toBe(0);
    const claude = parse(result.stdout);
    expect(claude.ANTHROPIC_BASE_URL).toBe("<unset>");
    expect(claude.ANTHROPIC_API_KEY).toBe("<unset>");
    expect(claude.CLAUDE_CONFIG_DIR).toBe("<unset>");
    const reason = await runChild("/bin/sh", ["-c", `. ${m.auth}; cmux_agent_auth_resolve claude; printf '%s %s' "$cmux_agent_auth_mode" "$cmux_agent_auth_reason"`],
      { env: { PATH: env.PATH, HOME: m.home } });
    expect(reason.stdout).toBe("own no-team-plane");
    // Nothing asked CodeRouter: there was no origin to ask.
    const calls = existsSync(m.calls) ? readFileSync(m.calls, "utf8") : "";
    expect(calls).not.toContain("agent-access");
  });

  test("with no CodeRouter origin, a stale model-plane pair never reaches codex or opencode", async () => {
    // The persisted OpenAI pair alone: its URL names CodeRouter but no CMUX_CODEROUTER_URL does. Own mode must
    // drop the URL with the placeholder key, or an own login would go to that endpoint.
    const m = machine();
    cmuxCodexConfig(m);
    writeFileSync(m.modelPlane, `export OPENAI_BASE_URL='${ORIGIN}/v1'\nexport OPENAI_API_KEY='${PLACEHOLDER}'\n`);
    const env = bootEnv(m);
    for (const name of ["CMUX_CODEROUTER_URL", "ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY"]) delete env[name];
    for (const agent of ["codex", "opencode"] as const) {
      const result = await runChild("/bin/bash", ["-c", `. ${m.config}; ${m.launchers[agent]} --resume x`], { env });
      expect(result.status).toBe(0);
      const child = parse(result.stdout);
      expect(child.OPENAI_BASE_URL).toBe("<unset>");
      expect(child.OPENAI_API_KEY).toBe("<unset>");
    }
    // A user's own endpoint with their own key stays.
    const own = await runChild("/bin/bash", ["-c", `. ${m.config}; export OPENAI_BASE_URL=https://api.example.test/v1 OPENAI_API_KEY=sk-user; ${m.launchers.codex} --resume x`], { env });
    expect(parse(own.stdout).OPENAI_BASE_URL).toBe("https://api.example.test/v1");
  });

  test("CMUX_<AGENT>_AUTH pins one launch over the recorded choice and the default", async () => {
    const m = machine();
    cmuxCodexConfig(m);
    for (const agent of AGENTS) choose(m, "own", agent);
    expect((await launch(m, "claude", { CMUX_CLAUDE_AUTH: "team" })).ANTHROPIC_API_KEY).toBe(PLACEHOLDER);
    expect((await launch(m, "codex", { CMUX_CODEX_AUTH: "team" })).args).toBe("--resume x");
    expect((await launch(m, "opencode", { CMUX_OPENCODE_AUTH: "team" })).OPENCODE_CONFIG).not.toBe("<unset>");
    // Anything else is ignored rather than trusted.
    expect((await launch(m, "claude", { CMUX_CLAUDE_AUTH: "bogus" })).ANTHROPIC_API_KEY).toBe("<unset>");
    const fresh = machine();
    expect((await launch(fresh, "claude", { CMUX_CLAUDE_AUTH: "own", FAKE_ACCESS: ALL })).ANTHROPIC_API_KEY).toBe("<unset>");
    expect(existsSync(fresh.calls)).toBe(false);
  });

  test("the account check sends only the placeholder, never a user's key", async () => {
    const m = machine();
    await launch(m, "claude", { FAKE_ACCESS: ALL }, "export ANTHROPIC_BASE_URL=https://proxy.example.test ANTHROPIC_API_KEY=sk-ant-real OPENAI_API_KEY=sk-openai-real;");
    const calls = readFileSync(m.calls, "utf8");
    expect(calls).toContain(`authorization: Bearer ${PLACEHOLDER}`);
    expect(calls).not.toContain("sk-ant-real");
    expect(calls).not.toContain("sk-openai-real");
  });

  test("the account answer is reused for a minute, then asked again", async () => {
    const m = machine();
    expect((await launch(m, "claude", { FAKE_ACCESS: ALL })).ANTHROPIC_API_KEY).toBe(PLACEHOLDER);
    expect((await launch(m, "claude", { FAKE_ACCESS: NONE })).ANTHROPIC_API_KEY).toBe(PLACEHOLDER);
    expect(readFileSync(m.calls, "utf8").trim().split("\n")).toHaveLength(1);
    writeFileSync(path.join(m.home, ".cache/cmux/agent-access"), "1 0 0 0\n");
    expect((await launch(m, "claude", { FAKE_ACCESS: NONE })).ANTHROPIC_API_KEY).toBe("<unset>");
  });

  test("a HOME the generators cannot write still starts every agent", async () => {
    const m = machine();
    for (const agent of AGENTS) choose(m, "team", agent);
    chmodSync(path.join(m.home, ".config/cmux"), 0o500);
    chmodSync(m.home, 0o500);
    try {
      for (const agent of ["claude", "codex"] as const) {
        const result = await runChild("/bin/bash", ["-c", `${m.launchers[agent]} --resume x`], { env: bootEnv(m) });
        expect(result.status).toBe(0);
        expect(parse(result.stdout).args).toBe("--resume x");
      }
    } finally {
      chmodSync(m.home, 0o700);
      chmodSync(path.join(m.home, ".config/cmux"), 0o700);
    }
  });

  test("a shell whose PATH puts other copies first still launches through the launchers", async () => {
    // The base's login PATH puts nvm's bin ahead of /usr/local/bin.
    const m = machine();
    cmuxCodexConfig(m);
    for (const agent of AGENTS) choose(m, "own", agent);
    const nvm = path.join(m.root, "nvm-bin");
    mkdirSync(nvm);
    for (const agent of AGENTS) {
      writeFileSync(path.join(nvm, agent), "#!/bin/sh\necho bypassed-the-launcher\n");
      chmodSync(path.join(nvm, agent), 0o755);
    }
    const config = routedAgentConfig(m);
    for (const agent of AGENTS) {
      const result = await runChild("/bin/bash", ["-c", `. ${config}; ${agent} --resume x`], {
        env: { ...bootEnv(m), PATH: `${nvm}:${m.bin}:${process.env.PATH ?? "/usr/bin:/bin"}` },
      });
      expect(result.stdout).not.toContain("bypassed");
      expect(parse(result.stdout).OPENAI_API_KEY).toBe("<unset>");
    }
  });

  test("a cmux-tui agent shim first on PATH keeps its place in front of the launcher", async () => {
    // The shim adds the pane's hook context, then finds the launcher further
    // down PATH; the shell function must not jump past it.
    const m = machine();
    cmuxCodexConfig(m);
    for (const agent of AGENTS) choose(m, "own", agent);
    const shims = path.join(m.root, "shims");
    const later = path.join(m.root, "later-bin");
    mkdirSync(shims);
    mkdirSync(later);
    for (const agent of ["claude", "codex"] as const) {
      writeFileSync(path.join(shims, agent), `#!/bin/sh\n# cmux-tui-${agent}-shim\necho via-the-shim\nexec ${m.launchers[agent]} "$@"\n`);
      chmodSync(path.join(shims, agent), 0o755);
    }
    const config = routedAgentConfig(m);
    for (const agent of ["claude", "codex"] as const) {
      const result = await runChild("/bin/bash", ["-c", `. ${config}; ${agent} --resume x`], {
        env: { ...bootEnv(m), PATH: `${shims}:${later}:${m.bin}:${process.env.PATH ?? "/usr/bin:/bin"}` },
      });
      expect(result.stdout.split("\n")[0]).toBe("via-the-shim");
      expect(parse(result.stdout.split("\n").slice(1).join("\n")).args).toContain("--resume x");
    }
  });

  test("codex --version from a shell needs no trust entry and no account check", async () => {
    const m = machine();
    const config = routedAgentConfig(m);
    const result = await runChild("/bin/bash", ["-c", `. ${config}; codex --version`], { env: bootEnv(m, { FAKE_ACCESS: ALL }) });
    expect(parse(result.stdout).args).toBe("--version");
    expect(existsSync(m.calls)).toBe(false);
  });

  test("--version and --help skip the mode resolution", async () => {
    const m = machine();
    for (const agent of AGENTS) {
      const result = await runChild(m.launchers[agent], ["--version"], { env: bootEnv(m, { FAKE_ACCESS: ALL }) });
      expect(result.status).toBe(0);
      expect(parse(result.stdout).args).toBe("--version");
    }
    expect(existsSync(m.calls)).toBe(false);
  });
});

describe("cr use", () => {
  async function cr(m: Machine, args: string[], extra: Record<string, string> = {}) {
    const shim = path.join(m.root, "cmux-adapter");
    writeFileSync(shim, GUEST_CMUX_SHIM);
    chmodSync(shim, 0o755);
    // The Cloud CLI facade hands `cr use …` to the adapter as `coderouter use …`.
    return runChild("/bin/sh", [shim, "coderouter", "use", ...args], {
      env: {
        PATH: `${m.bin}:${process.env.PATH ?? "/usr/bin:/bin"}`,
        HOME: m.home,
        LANG: "en_US.UTF-8",
        CMUX_TUI_BIN: "/usr/bin/true",
        CMUX_AGENT_AUTH_LIB: m.auth,
        // What a machine shell exports after agent-config.sh set Claude's pair aside.
        CMUX_CODEROUTER_URL: ORIGIN,
        OPENAI_BASE_URL: `${ORIGIN}/v1`,
        OPENAI_API_KEY: PLACEHOLDER,
        CMUX_CLAUDE_TEAM_BASE_URL: ORIGIN,
        CMUX_CLAUDE_TEAM_API_KEY: PLACEHOLDER,
        ...extra,
      },
    });
  }
  const choice = (m: Machine, agent: Agent) => {
    const file = path.join(m.home, ".config/cmux/agent-auth", agent);
    return existsSync(file) ? readFileSync(file, "utf8") : null;
  };

  test("without an agent, own and team apply to every agent the launchers read", async () => {
    const m = machine();
    cmuxCodexConfig(m);
    const own = await cr(m, ["own"]);
    expect(own.status).toBe(0);
    for (const agent of AGENTS) expect(choice(m, agent)).toBe("own\n");
    expect(own.stdout).toContain("Claude Code: your own login (chosen with cr use)");
    expect(own.stdout).toContain("Codex: your own login (chosen with cr use)");
    expect(own.stdout).toContain("OpenCode: your own login (chosen with cr use)");
    expect(own.stdout).toContain("/login in Claude Code");
    expect(own.stdout).toContain("codex login");
    expect(own.stdout).toContain("opencode auth login");
    expect(own.stdout).toContain("next time you start each agent");
    expect((await launch(m, "claude")).ANTHROPIC_API_KEY).toBe("<unset>");
    expect((await launch(m, "codex")).args).toBe('-c model_provider="openai" --resume x');

    const team = await cr(m, ["team"], { FAKE_ACCESS: access(true, false, true) });
    expect(team.status).toBe(0);
    for (const agent of AGENTS) expect(choice(m, agent)).toBe("team\n");
    expect(team.stdout).toContain("Codex: the team's CodeRouter accounts (chosen with cr use)");
    // Team mode without an account for the agent points at both ways out.
    expect(team.stdout).toContain("The team has no Codex account yet. Add one with cr add codex, or switch with cr use own codex.");
    expect(team.stdout).not.toContain("no Claude Code account");
    expect((await launch(m, "codex")).args).toBe("--resume x");
  });

  test("a shared-team machine never selects a personal agent login", async () => {
    const m = machine();
    const kind = resolveVmGuestKind({ userId: "user-owner", ownerTeamId: "team-shared" });
    expect(kind).toBe("team");
    const soloTeamKind = resolveVmGuestKind({ userId: "user-owner", ownerTeamId: "team-solo" });
    expect(soloTeamKind).toBe("team");
    const modelEnv = path.join(m.root, "model-plane.env");
    writeFileSync(modelEnv, `export CMUX_CODEROUTER_URL='${ORIGIN}'\nexport OPENAI_API_KEY='${PLACEHOLDER}'\n`);
    const synced = await runChild("/bin/sh", [path.join(templateDir, "cmux-vm-kind-sync")], {
      env: {
        PATH: `${m.bin}:${process.env.PATH ?? "/usr/bin:/bin"}`,
        CMUX_VM_KIND_FILE: m.kind,
        CMUX_VM_MODEL_ENV_FILE: modelEnv,
        FAKE_VM_KIND: kind!,
      },
    });
    expect(synced.status).toBe(0);
    expect(readFileSync(m.kind, "utf8")).toBe("team\n");
    cmuxCodexConfig(m);
    for (const agent of AGENTS) {
      choose(m, "own", agent);
      signIn(m, agent);
    }

    const claude = await launch(m, "claude", { FAKE_ACCESS: ALL });
    expect(claude.ANTHROPIC_BASE_URL).toBe(ORIGIN);
    expect(claude.ANTHROPIC_API_KEY).toBe(PLACEHOLDER);
    expect(claude.CLAUDE_CONFIG_DIR).toBe(path.join(m.home, ".config/cmux/claude-team"));
    const codex = await launch(m, "codex", { FAKE_ACCESS: ALL });
    expect(codex.args).toBe("--resume x");
    expect(codex.OPENAI_API_KEY).toBe(PLACEHOLDER);
    expect(codex.CODEX_HOME).toBe(path.join(m.home, ".config/cmux/codex-team"));
    const opencode = await launch(m, "opencode", { FAKE_ACCESS: ALL });
    expect(opencode.OPENCODE_CONFIG).toBe(path.join(m.home, ".config/cmux/opencode-team.json"));
    expect(opencode.OPENAI_API_KEY).toBe(PLACEHOLDER);
    expect(opencode.XDG_DATA_HOME).toBe(path.join(m.home, ".local/share/cmux-team"));
    expect(opencode.XDG_CONFIG_HOME).toBe(path.join(m.home, ".config/cmux-team"));

    const forcedClaude = await launch(m, "claude", {
      ANTHROPIC_API_KEY: "personal-claude",
      ANTHROPIC_AUTH_TOKEN: "personal-token",
      CLAUDE_CODE_USE_BEDROCK: "1",
      CLAUDE_CODE_USE_VERTEX: "1",
      CLAUDE_CODE_USE_FOUNDRY: "1",
      FAKE_ACCESS: ALL,
    });
    expect(forcedClaude.ANTHROPIC_API_KEY).toBe(PLACEHOLDER);
    expect(forcedClaude.ANTHROPIC_AUTH_TOKEN).toBe("<unset>");
    expect(forcedClaude.CLAUDE_CODE_USE_BEDROCK).toBe("<unset>");
    expect(forcedClaude.CLAUDE_CODE_USE_VERTEX).toBe("<unset>");
    expect(forcedClaude.CLAUDE_CODE_USE_FOUNDRY).toBe("<unset>");
    expect((await launch(m, "codex", { OPENAI_API_KEY: "personal-codex", FAKE_ACCESS: ALL })).OPENAI_API_KEY).toBe(PLACEHOLDER);
    const forcedOpenCode = await launch(m, "opencode", {
      OPENAI_API_KEY: "personal-opencode",
      ANTHROPIC_API_KEY: "personal-anthropic",
      OPENCODE_CONFIG_DIR: "/personal/opencode-config",
      FAKE_ACCESS: ALL,
    });
    expect(forcedOpenCode.OPENAI_API_KEY).toBe(PLACEHOLDER);
    expect(forcedOpenCode.ANTHROPIC_API_KEY).toBe("<unset>");
    expect(forcedOpenCode.OPENCODE_CONFIG_DIR).toBe("<unset>");
    const persistedPath = path.join(m.home, ".config/cmux/model-plane.env");
    const persistedPlane = existsSync(persistedPath) ? readFileSync(persistedPath, "utf8") : "";
    expect(persistedPlane).not.toContain("personal-claude");
    expect(persistedPlane).not.toContain("personal-token");
    expect(persistedPlane).not.toContain("personal-codex");
    expect(persistedPlane).not.toContain("personal-opencode");
    expect(persistedPlane).not.toContain("personal-anthropic");

    const status = await cr(m, ["--json"], { FAKE_ACCESS: ALL });
    expect(status.stdout).toBe(
      '{"agents":[{"agent":"claude","mode":"team","reason":"shared-machine","chosen":false},'
      + '{"agent":"codex","mode":"team","reason":"shared-machine","chosen":false},'
      + '{"agent":"opencode","mode":"team","reason":"shared-machine","chosen":false}]}\n',
    );

    const blocked = machine();
    writeFileSync(blocked.kind, "team\n");
    mkdirSync(path.join(blocked.home, ".config"), { recursive: true });
    writeFileSync(path.join(blocked.home, ".config/cmux"), "not a directory");
    for (const agent of ["claude", "codex"] as const) {
      const refused = await runChild(blocked.launchers[agent], ["--resume", "x"], { env: bootEnv(blocked) });
      expect(refused.status).not.toBe(0);
      expect(refused.stdout).not.toContain("args=");
    }
    mkdirSync(path.join(blocked.home, ".local/share"), { recursive: true });
    writeFileSync(path.join(blocked.home, ".local/share/cmux-team"), "not a directory");
    const openCodeRefused = await runChild(blocked.launchers.opencode, ["--resume", "x"], { env: bootEnv(blocked) });
    expect(openCodeRefused.status).not.toBe(0);
    expect(openCodeRefused.stdout).not.toContain("args=");
  });

  test("a team machine runs Claude on its creator's transferred login, and only on that", async () => {
    // What the app's credential transfer (CloudCredentialInstaller) leaves for the machine's creator:
    // the choice `own`, the token in ~/.claude/settings.json's env and the standard login marker.
    const transferred = (m: Machine) => {
      choose(m, "own");
      signIn(m);
      writeFileSync(path.join(m.home, ".claude/settings.json"), JSON.stringify({ env: { CLAUDE_CODE_OAUTH_TOKEN: "sk-ant-oat-creator" } }));
    };
    const m = machine();
    writeFileSync(m.kind, "team\n");
    transferred(m);
    const claude = await launch(m, "claude", { FAKE_ACCESS: ALL });
    expect(claude.ANTHROPIC_BASE_URL).toBe("<unset>");
    expect(claude.ANTHROPIC_API_KEY).toBe("<unset>");
    expect(claude.CLAUDE_CONFIG_DIR).toBe("<unset>");
    expect((await cr(m, ["claude", "--json"], { FAKE_ACCESS: ALL })).stdout)
      .toBe('{"agents":[{"agent":"claude","mode":"own","reason":"login","chosen":false}]}\n');
    // Codex and OpenCode stay shared: only Claude's login is transferred at a start.
    expect((await launch(m, "codex", { FAKE_ACCESS: ALL })).CODEX_HOME).toBe(path.join(m.home, ".config/cmux/codex-team"));

    // Without the transfer's token, or with a choice other than own, the team machine stays shared.
    for (const partial of [
      (n: Machine) => { choose(n, "own"); signIn(n); },
      (n: Machine) => { transferred(n); choose(n, "team"); },
      (n: Machine) => { transferred(n); writeFileSync(path.join(n.home, ".claude/settings.json"), JSON.stringify({ env: { CLAUDE_CODE_OAUTH_TOKEN: " " } })); },
      (n: Machine) => { transferred(n); writeFileSync(path.join(n.home, ".claude/settings.json"), "not json"); },
    ]) {
      const n = machine();
      writeFileSync(n.kind, "team\n");
      partial(n);
      const shared = await launch(n, "claude", { FAKE_ACCESS: ALL });
      expect(shared.ANTHROPIC_API_KEY).toBe(PLACEHOLDER);
      expect(shared.CLAUDE_CONFIG_DIR).toBe(path.join(n.home, ".config/cmux/claude-team"));
    }
  });

  test("an agent argument limits the change to that agent", async () => {
    const m = machine();
    expect((await cr(m, ["own", "codex"])).status).toBe(0);
    expect(choice(m, "codex")).toBe("own\n");
    expect(choice(m, "claude")).toBeNull();
    expect(choice(m, "opencode")).toBeNull();
    const status = await cr(m, ["codex", "--json"], { FAKE_ACCESS: ALL });
    expect(status.stdout).toBe('{"agents":[{"agent":"codex","mode":"own","reason":"chosen","chosen":true}]}\n');
  });

  test("with no mode it reports each agent's mode and why; auto forgets the choice", async () => {
    const m = machine();
    expect((await cr(m, ["--json"], { FAKE_ACCESS: access(true, false, true) })).stdout).toBe(
      '{"agents":[{"agent":"claude","mode":"team","reason":"team-account","chosen":false},'
      + '{"agent":"codex","mode":"own","reason":"no-team-account","chosen":false},'
      + '{"agent":"opencode","mode":"team","reason":"team-account","chosen":false}]}\n',
    );
    signIn(m, "claude");
    choose(m, "team", "codex");
    const status = await cr(m, [], { FAKE_ACCESS: ALL });
    expect(status.stdout).toBe([
      "Claude Code: your own login (signed in on this machine)",
      "Codex: the team's CodeRouter accounts (chosen with cr use)",
      "OpenCode: the team's CodeRouter accounts (default: the team has an account for it)",
      "",
    ].join("\n"));
    expect((await cr(m, ["auto"])).status).toBe(0);
    for (const agent of AGENTS) expect(choice(m, agent)).toBeNull();
  });

  test("a machine shell sends `cr use` to the adapter and every other command to the installed CLI", async () => {
    // The pinned Cloud CLI facade forwards `use` to the adapter only from the
    // release that knows the verb; the shell routes it until then.
    const m = machine();
    const adapter = path.join(m.root, "adapter");
    writeFileSync(adapter, '#!/bin/sh\necho "adapter $*"\n');
    chmodSync(adapter, 0o755);
    for (const name of ["cr", "coderouter", "cmux"]) {
      writeFileSync(path.join(m.bin, name), `#!/bin/sh\necho "installed ${name} $*"\n`);
      chmodSync(path.join(m.bin, name), 0o755);
    }
    const config = path.join(m.root, "agent-config-cr.sh");
    writeFileSync(config, readFileSync(m.config, "utf8").replaceAll("/usr/local/libexec/cmux-cloud-adapter", adapter));
    const run = async (command: string) =>
      (await runChild("/bin/bash", ["-c", `. ${config}; ${command}`], { env: bootEnv(m) })).stdout.trim();
    expect(await run("cr use own codex")).toBe("adapter coderouter use own codex");
    expect(await run("coderouter use --json")).toBe("adapter coderouter use --json");
    expect(await run("cmux cr use team")).toBe("adapter coderouter use team");
    expect(await run("cmux coderouter use")).toBe("adapter coderouter use");
    expect(await run("cr accounts --json")).toBe("installed cr accounts --json");
    expect(await run("cr")).toBe("installed cr");
    expect(await run("cmux tree --json")).toBe("installed cmux tree --json");
    expect(await run("cmux cr accounts")).toBe("installed cmux cr accounts");
  });

  test("an image without the switch says how to use an own login there", async () => {
    const m = machine();
    const result = await cr(m, ["own"], { CMUX_AGENT_AUTH_LIB: path.join(m.root, "missing.sh") });
    expect(result.status).toBe(2);
    expect(result.stderr).toContain("unset ANTHROPIC_API_KEY ANTHROPIC_BASE_URL");
    expect(result.stderr).toContain("codex -c model_provider=openai");
    expect(result.stderr).toContain("env -u OPENAI_BASE_URL -u ANTHROPIC_BASE_URL opencode");
    expect(existsSync(path.join(m.home, ".config/cmux/agent-auth"))).toBe(false);
  });

  test("a choice that cannot be written fails loudly instead of reporting it", async () => {
    const m = machine();
    mkdirSync(path.join(m.home, ".config/cmux/agent-auth"), { recursive: true });
    chmodSync(path.join(m.home, ".config/cmux/agent-auth"), 0o500);
    try {
      const result = await cr(m, ["own"]);
      expect(result.status).toBe(1);
      expect(result.stderr).toContain("could not record the choice");
      expect(result.stdout).toBe("");
    } finally {
      chmodSync(path.join(m.home, ".config/cmux/agent-auth"), 0o700);
    }
  });

  test("says when an exported Claude key or endpoint outranks the mode", async () => {
    const m = machine();
    const result = await cr(m, ["team", "claude"], { ANTHROPIC_API_KEY: "sk-ant-user", FAKE_ACCESS: ALL });
    expect(result.stdout).toContain("ANTHROPIC_API_KEY or ANTHROPIC_BASE_URL is set in this environment");
    expect(readFileSync(m.calls, "utf8")).not.toContain("sk-ant-user");
  });

  test("rejects unknown arguments and a second mode", async () => {
    const m = machine();
    expect((await cr(m, ["mine"])).status).toBe(2);
    const twice = await cr(m, ["own", "team"]);
    expect(twice.status).toBe(2);
    expect(twice.stderr).toContain("one mode");
    expect(existsSync(path.join(m.home, ".config/cmux/agent-auth"))).toBe(false);
  });
});
