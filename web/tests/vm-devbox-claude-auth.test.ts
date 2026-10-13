import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { GUEST_CMUX_SHIM } from "../services/vms/guestCli";
import { runChild } from "./helpers/run-child";

// Claude Code ranks ANTHROPIC_API_KEY above its own /login. These tests pin
// the Cloud machine's precedence: the CodeRouter pair never sits in the shell
// env, the claude launcher adds it only in team mode, and `cr use` records the
// choice the launcher reads.

const templateDir = path.join(import.meta.dirname, "../services/vms/images/devbox");
const ORIGIN = "https://coderouter.cmux.test";
const PLACEHOLDER = "cmux-vm-edge-placeholder";
const ACTIVE = JSON.stringify({ teamId: "t", accounts: [{ id: "a", state: "active" }] });
const DISABLED = JSON.stringify({ teamId: "t", accounts: [{ id: "a", state: "disabled" }] });

const roots: string[] = [];
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

type Machine = { root: string; home: string; bin: string; launcher: string; calls: string };

/**
 * A HOME, a fake `claude` that prints the auth env it was started with, a
 * fake `curl` answering the team account check from $FAKE_CURL_BODY (exit 7
 * when unset), and the image launcher pointed at this tree.
 */
function machine(): Machine {
  const root = mkdtempSync(path.join(tmpdir(), "cmux-claude-auth-"));
  roots.push(root);
  const home = path.join(root, "home");
  const bin = path.join(root, "bin");
  mkdirSync(home, { recursive: true });
  mkdirSync(bin, { recursive: true });
  const calls = path.join(root, "curl.calls");
  const real = path.join(root, "claude-real");
  writeFileSync(
    real,
    [
      "#!/bin/sh",
      'printf "ANTHROPIC_BASE_URL=%s\\n" "${ANTHROPIC_BASE_URL-<unset>}"',
      'printf "ANTHROPIC_API_KEY=%s\\n" "${ANTHROPIC_API_KEY-<unset>}"',
      'printf "ANTHROPIC_CUSTOM_HEADERS=%s\\n" "${ANTHROPIC_CUSTOM_HEADERS-<unset>}"',
      'printf "args=%s\\n" "$*"',
      "",
    ].join("\n"),
  );
  writeFileSync(
    path.join(bin, "curl"),
    `#!/bin/sh\nprintf '%s\\n' "$*" >> ${JSON.stringify(calls)}\n[ -n "\${FAKE_CURL_BODY-}" ] || exit 7\nprintf '%s' "$FAKE_CURL_BODY"\n`,
  );
  const launcher = path.join(root, "claude");
  writeFileSync(
    launcher,
    readFileSync(path.join(templateDir, "cmux-claude"), "utf8")
      .replaceAll("/etc/cmux/agent-config.sh", path.join(templateDir, "agent-config.sh"))
      .replaceAll("/etc/cmux/agent-auth.sh", path.join(templateDir, "agent-auth.sh"))
      .replaceAll("/usr/local/libexec/cmux-claude-real", real),
  );
  for (const file of [real, path.join(bin, "curl"), launcher]) chmodSync(file, 0o755);
  return { root, home, bin, launcher, calls };
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

/** Starts claude from a shell that sourced agent-config.sh, the way every terminal does. */
async function launch(m: Machine, extra: Record<string, string> = {}, shellPrefix = "") {
  const result = await runChild(
    "/bin/bash",
    ["-c", `. ${path.join(templateDir, "agent-config.sh")}; ${shellPrefix} ${m.launcher} --resume x`],
    { env: bootEnv(m, extra) },
  );
  expect(result.stderr).toBe("");
  expect(result.status).toBe(0);
  return Object.fromEntries(result.stdout.trim().split("\n").map((line) => [line.slice(0, line.indexOf("=")), line.slice(line.indexOf("=") + 1)] as [string, string]));
}

function choose(m: Machine, mode: string): void {
  mkdirSync(path.join(m.home, ".config/cmux/agent-auth"), { recursive: true });
  writeFileSync(path.join(m.home, ".config/cmux/agent-auth/claude"), `${mode}\n`);
}

function signIn(m: Machine): void {
  mkdirSync(path.join(m.home, ".claude"), { recursive: true });
  writeFileSync(path.join(m.home, ".claude/.credentials.json"), JSON.stringify({ claudeAiOauth: { accessToken: "x" } }));
}

describe("Cloud machine Claude Code sign-in precedence", () => {
  test("a shell never exports the CodeRouter pair, and still persists it for the launcher", async () => {
    const m = machine();
    const probe = `printf '%s|%s|%s|%s' "\${ANTHROPIC_BASE_URL-unset}" "\${ANTHROPIC_API_KEY-unset}" "\${CMUX_CLAUDE_TEAM_BASE_URL-}" "\${CMUX_CLAUDE_TEAM_API_KEY-}"`;
    const first = await runChild("/bin/bash", ["-c", `. ${path.join(templateDir, "agent-config.sh")}; ${probe}`], { env: bootEnv(m) });
    expect(first.stdout).toBe(`unset|unset|${ORIGIN}|${PLACEHOLDER}`);
    // A nested shell inherits only the set-aside pair; it re-persists the
    // model-plane names and keeps the pair out of its own env too.
    const nested = await runChild(
      "/bin/bash",
      ["-c", `. ${path.join(templateDir, "agent-config.sh")}; bash -c '. ${path.join(templateDir, "agent-config.sh")}; ${probe.replaceAll("'", "'\\''")}'`],
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
    const own = await runChild("/bin/bash", ["-c", `. ${path.join(templateDir, "agent-config.sh")}; ${probe}`], {
      env: bootEnv(m, { ANTHROPIC_BASE_URL: "https://api.example.test", ANTHROPIC_API_KEY: "sk-ant-user" }),
    });
    expect(own.stdout).toBe("https://api.example.test|sk-ant-user");
    // A key the user exported after the pair was set aside survives a nested shell.
    const nested = await runChild(
      "/bin/bash",
      ["-c", `. ${path.join(templateDir, "agent-config.sh")}; export ANTHROPIC_API_KEY=sk-ant-user; bash -c '. ${path.join(templateDir, "agent-config.sh")}; ${probe.replaceAll("'", "'\\''")}'`],
      { env: bootEnv(m) },
    );
    expect(nested.stdout).toBe("unset|sk-ant-user");
  });

  test("own mode starts claude with no CodeRouter env, so its /login is what it uses", async () => {
    const m = machine();
    choose(m, "own");
    const env = await launch(m, { CMUX_WORKSPACE_ID: "ws-1", CMUX_SURFACE_ID: "sf-1" });
    expect(env).toEqual({
      ANTHROPIC_BASE_URL: "<unset>",
      ANTHROPIC_API_KEY: "<unset>",
      ANTHROPIC_CUSTOM_HEADERS: "<unset>",
      args: "--resume x",
    });
    // An explicit choice needs no account check.
    expect(existsSync(m.calls)).toBe(false);
  });

  test("own mode also drops the pair a shell from an older agent-config still exports", async () => {
    const m = machine();
    choose(m, "own");
    const env = await launch(m, {}, `export ANTHROPIC_BASE_URL=${ORIGIN} ANTHROPIC_API_KEY=${PLACEHOLDER};`);
    expect(env.ANTHROPIC_BASE_URL).toBe("<unset>");
    expect(env.ANTHROPIC_API_KEY).toBe("<unset>");
  });

  test("team mode adds the CodeRouter pair and usage headers, even over an own login", async () => {
    const m = machine();
    choose(m, "team");
    signIn(m);
    const env = await launch(m, { CMUX_WORKSPACE_ID: "ws-1" });
    expect(env.ANTHROPIC_BASE_URL).toBe(ORIGIN);
    expect(env.ANTHROPIC_API_KEY).toBe(PLACEHOLDER);
    expect(env.ANTHROPIC_CUSTOM_HEADERS).toBe("x-cmux-workspace-id: ws-1");
  });

  test("a user-set key wins in every mode", async () => {
    for (const mode of ["team", "own"]) {
      const m = machine();
      choose(m, mode);
      const env = await launch(m, {}, "export ANTHROPIC_API_KEY=sk-ant-user;");
      expect(env.ANTHROPIC_API_KEY).toBe("sk-ant-user");
      expect(env.ANTHROPIC_BASE_URL).toBe("<unset>");
    }
  });

  test("with no choice, an existing /login counts as choosing own", async () => {
    const m = machine();
    signIn(m);
    const env = await launch(m, { FAKE_CURL_BODY: ACTIVE });
    expect(env.ANTHROPIC_API_KEY).toBe("<unset>");
    expect(existsSync(m.calls)).toBe(false);
  });

  test("with no choice and no login, the team's accounts decide", async () => {
    const usable = machine();
    expect((await launch(usable, { FAKE_CURL_BODY: ACTIVE })).ANTHROPIC_API_KEY).toBe(PLACEHOLDER);
    // The check goes to the account list through the edge, with the placeholder only.
    expect(readFileSync(usable.calls, "utf8")).toContain(`${ORIGIN}/api/coderouter/claude-upstream`);
    expect(readFileSync(usable.calls, "utf8")).toContain(`authorization: Bearer ${PLACEHOLDER}`);

    // No usable account: Claude Code shows its own sign-in instead of a 403.
    for (const body of [DISABLED, JSON.stringify({ teamId: "t", accounts: [] })]) {
      const none = machine();
      expect((await launch(none, { FAKE_CURL_BODY: body })).ANTHROPIC_API_KEY).toBe("<unset>");
    }

    // No answer keeps the long-standing default.
    for (const body of [undefined, "<html>"]) {
      const unknown = machine();
      const env = await launch(unknown, body === undefined ? {} : { FAKE_CURL_BODY: body });
      expect(env.ANTHROPIC_API_KEY).toBe(PLACEHOLDER);
    }
  });

  test("CMUX_CLAUDE_AUTH pins one launch over the recorded choice and the default", async () => {
    const m = machine();
    choose(m, "own");
    expect((await launch(m, { CMUX_CLAUDE_AUTH: "team" })).ANTHROPIC_API_KEY).toBe(PLACEHOLDER);
    const fresh = machine();
    expect((await launch(fresh, { CMUX_CLAUDE_AUTH: "own", FAKE_CURL_BODY: ACTIVE })).ANTHROPIC_API_KEY).toBe("<unset>");
    expect(existsSync(fresh.calls)).toBe(false);
    // Anything else is ignored rather than trusted.
    expect((await launch(m, { CMUX_CLAUDE_AUTH: "bogus" })).ANTHROPIC_API_KEY).toBe("<unset>");
  });

  test("a one-off user key is never persisted, so team mode keeps working afterwards", async () => {
    const m = machine();
    choose(m, "team");
    // `ANTHROPIC_API_KEY=... claude` once: the launcher sources agent-config.sh.
    const once = await launch(m, {}, "ANTHROPIC_API_KEY=sk-ant-oneoff");
    expect(once.ANTHROPIC_API_KEY).toBe("sk-ant-oneoff");
    const plane = readFileSync(path.join(m.home, ".config/cmux/model-plane.env"), "utf8");
    expect(plane).not.toContain("sk-ant-oneoff");
    expect(plane).toContain(`export ANTHROPIC_API_KEY='${PLACEHOLDER}'`);
    // A fresh shell without the boot env reads the persisted file only.
    const fresh = await runChild("/bin/bash", ["-c", `. ${path.join(templateDir, "agent-config.sh")}; ${m.launcher}`], {
      env: { PATH: `${m.bin}:${process.env.PATH ?? "/usr/bin:/bin"}`, HOME: m.home },
    });
    expect(fresh.stdout).toContain(`ANTHROPIC_API_KEY=${PLACEHOLDER}\n`);
    expect(fresh.stdout).toContain(`ANTHROPIC_BASE_URL=${ORIGIN}\n`);
  });

  test("the account check sends only the placeholder, never a user's key", async () => {
    const m = machine();
    await launch(m, { FAKE_CURL_BODY: ACTIVE }, "export ANTHROPIC_BASE_URL=https://proxy.example.test ANTHROPIC_API_KEY=sk-ant-real OPENAI_API_KEY=sk-openai-real;");
    const calls = readFileSync(m.calls, "utf8");
    expect(calls).toContain(`authorization: Bearer ${PLACEHOLDER}`);
    expect(calls).not.toContain("sk-ant-real");
    expect(calls).not.toContain("sk-openai-real");
  });

  test("the account answer is reused for a minute", async () => {
    const m = machine();
    expect((await launch(m, { FAKE_CURL_BODY: ACTIVE })).ANTHROPIC_API_KEY).toBe(PLACEHOLDER);
    expect((await launch(m, { FAKE_CURL_BODY: DISABLED })).ANTHROPIC_API_KEY).toBe(PLACEHOLDER);
    expect(readFileSync(m.calls, "utf8").trim().split("\n")).toHaveLength(1);
    // An expired answer is asked again.
    writeFileSync(path.join(m.home, ".cache/cmux/claude-team-accounts"), "1 0\n");
    expect((await launch(m, { FAKE_CURL_BODY: DISABLED })).ANTHROPIC_API_KEY).toBe("<unset>");
  });

  test("a HOME the generators cannot write still starts claude", async () => {
    const m = machine();
    choose(m, "team");
    chmodSync(path.join(m.home, ".config/cmux"), 0o500);
    chmodSync(m.home, 0o500);
    try {
      const result = await runChild("/bin/bash", ["-c", `${m.launcher} --resume x`], { env: bootEnv(m) });
      expect(result.status).toBe(0);
      expect(result.stdout).toContain(`ANTHROPIC_API_KEY=${PLACEHOLDER}\n`);
      expect(result.stdout).toContain("args=--resume x");
    } finally {
      chmodSync(m.home, 0o700);
      chmodSync(path.join(m.home, ".config/cmux"), 0o700);
    }
  });

  test("a shell whose PATH puts another claude first still launches through the launcher", async () => {
    // The base's login PATH puts nvm's bin ahead of /usr/local/bin/claude.
    const m = machine();
    choose(m, "team");
    const nvm = path.join(m.root, "nvm-bin");
    mkdirSync(nvm);
    writeFileSync(path.join(nvm, "claude"), "#!/bin/sh\necho nvm-claude-bypassed-the-launcher\n");
    chmodSync(path.join(nvm, "claude"), 0o755);
    const config = path.join(m.root, "agent-config.sh");
    writeFileSync(config, readFileSync(path.join(templateDir, "agent-config.sh"), "utf8").replaceAll("/etc/cmux/claude", m.launcher));
    const result = await runChild("/bin/bash", ["-c", `. ${config}; claude --resume x`], {
      env: { ...bootEnv(m), PATH: `${nvm}:${m.bin}:${process.env.PATH ?? "/usr/bin:/bin"}` },
    });
    expect(result.stdout).not.toContain("bypassed");
    expect(result.stdout).toContain(`ANTHROPIC_API_KEY=${PLACEHOLDER}\n`);
    expect(result.stdout).toContain("args=--resume x");
  });

  test("--version and --help skip the mode resolution", async () => {
    const m = machine();
    const result = await runChild(m.launcher, ["--version"], { env: bootEnv(m, { FAKE_CURL_BODY: ACTIVE }) });
    expect(result.status).toBe(0);
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
        CMUX_AGENT_AUTH_LIB: path.join(templateDir, "agent-auth.sh"),
        // What a machine shell exports after agent-config.sh set the pair aside.
        CMUX_CODEROUTER_URL: ORIGIN,
        OPENAI_API_KEY: PLACEHOLDER,
        CMUX_CLAUDE_TEAM_BASE_URL: ORIGIN,
        CMUX_CLAUDE_TEAM_API_KEY: PLACEHOLDER,
        ...extra,
      },
    });
  }

  test("own and team record the choice the launcher reads, and say it applies at the next launch", async () => {
    const m = machine();
    const own = await cr(m, ["own"]);
    expect(own.status).toBe(0);
    expect(readFileSync(path.join(m.home, ".config/cmux/agent-auth/claude"), "utf8")).toBe("own\n");
    expect(own.stdout).toContain("Claude Code: your own login (chosen with cr use)");
    expect(own.stdout).toContain("next time you start claude");
    expect(own.stdout).toContain("/login");
    expect((await launch(m, { FAKE_CURL_BODY: ACTIVE })).ANTHROPIC_API_KEY).toBe("<unset>");

    const team = await cr(m, ["team"], { FAKE_CURL_BODY: DISABLED });
    expect(team.status).toBe(0);
    expect(readFileSync(path.join(m.home, ".config/cmux/agent-auth/claude"), "utf8")).toBe("team\n");
    expect(team.stdout).toContain("Claude Code: the team's CodeRouter accounts (chosen with cr use)");
    // Team mode without a usable account points at both ways out.
    expect(team.stdout).toContain("cr add claude");
    expect(team.stdout).toContain("cr use own");
    expect((await launch(m)).ANTHROPIC_API_KEY).toBe(PLACEHOLDER);
  });

  test("with no argument it reports the resolved mode and why; auto forgets the choice", async () => {
    const m = machine();
    expect((await cr(m, ["--json"], { FAKE_CURL_BODY: ACTIVE })).stdout).toBe('{"agent":"claude","mode":"team","reason":"team-account","chosen":false}\n');
    expect((await cr(m, ["--json"], { FAKE_CURL_BODY: DISABLED })).stdout).toBe('{"agent":"claude","mode":"own","reason":"no-team-account","chosen":false}\n');
    signIn(m);
    const status = await cr(m, []);
    expect(status.stdout).toBe("Claude Code: your own login (signed in on this machine with /login or CLAUDE_CODE_OAUTH_TOKEN)\n");
    choose(m, "team");
    expect((await cr(m, ["--json"])).stdout).toBe('{"agent":"claude","mode":"team","reason":"chosen","chosen":true}\n');
    expect((await cr(m, ["auto"])).status).toBe(0);
    expect(existsSync(path.join(m.home, ".config/cmux/agent-auth/claude"))).toBe(false);
  });

  test("an image without the switch says how to use an own login there", async () => {
    const m = machine();
    const result = await cr(m, ["own"], { CMUX_AGENT_AUTH_LIB: path.join(m.root, "missing.sh") });
    expect(result.status).toBe(2);
    expect(result.stderr).toContain("unset ANTHROPIC_API_KEY ANTHROPIC_BASE_URL");
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

  test("says when an exported key or endpoint outranks the mode", async () => {
    const m = machine();
    const result = await cr(m, ["team"], { ANTHROPIC_API_KEY: "sk-ant-user", FAKE_CURL_BODY: ACTIVE });
    expect(result.stdout).toContain("ANTHROPIC_API_KEY or ANTHROPIC_BASE_URL is set in this environment");
    expect(readFileSync(m.calls, "utf8")).not.toContain("sk-ant-user");
  });

  test("rejects unknown arguments and a second mode", async () => {
    const m = machine();
    expect((await cr(m, ["mine"])).status).toBe(2);
    const twice = await cr(m, ["own", "team"]);
    expect(twice.status).toBe(2);
    expect(twice.stderr).toContain("one mode");
    expect(existsSync(path.join(m.home, ".config/cmux/agent-auth/claude"))).toBe(false);
  });
});
