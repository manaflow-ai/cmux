import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test } from "bun:test";
import {
  agentRoutingEnsureCommand,
  agentRoutingStateToken,
  buildAgentRoutingEnsureScript,
  buildAgentRoutingMergeScript,
  maskTenantKey,
  subrouterTenantBaseUrl,
  validateSubrouterTenantKey,
  validateSubrouterUrl,
  type AgentRoutingConfig,
} from "../services/vms/agentRouting";

const config: AgentRoutingConfig = {
  subrouterUrl: "https://subrouter.example.com",
  subrouterTenantKey: "srt_abcdef123456",
};

describe("subrouter URL validation", () => {
  test("accepts http(s) URLs and strips trailing slashes", () => {
    expect(validateSubrouterUrl("https://subrouter.example.com/")).toEqual({
      ok: true,
      value: "https://subrouter.example.com",
    });
    expect(validateSubrouterUrl("http://10.0.0.5:8080")).toEqual({
      ok: true,
      value: "http://10.0.0.5:8080",
    });
  });

  test("rejects non-http schemes, credentials, queries, and garbage", () => {
    for (const raw of [
      "ftp://example.com",
      "file:///etc/passwd",
      "https://user:pass@example.com",
      "https://example.com/?a=1",
      "https://example.com/#frag",
      "not a url",
      "",
      42,
      null,
    ]) {
      const result = validateSubrouterUrl(raw);
      expect(result.ok).toBe(false);
    }
  });
});

describe("subrouter tenant key validation", () => {
  test("accepts URL-path-safe keys", () => {
    expect(validateSubrouterTenantKey(" srt_abcdef123456 ")).toEqual({
      ok: true,
      value: "srt_abcdef123456",
    });
  });

  test("rejects short keys and keys unsafe in a URL path segment", () => {
    for (const raw of ["", "short", "has space key", "slash/key1", "key\nline", 42, null, `x${"y".repeat(600)}`]) {
      expect(validateSubrouterTenantKey(raw).ok).toBe(false);
    }
  });
});

describe("tenant key masking", () => {
  test("keeps a short prefix and suffix only", () => {
    expect(maskTenantKey("srt_abcdef123456")).toBe("srt_ab...56");
  });

  test("hides almost everything for short keys", () => {
    expect(maskTenantKey("srt_abc")).toBe("sr...");
  });
});

describe("ensure script generation", () => {
  test("apply script writes the tenant env file and codex/claude wiring", () => {
    const script = buildAgentRoutingEnsureScript(config);
    const tenantBase = subrouterTenantBaseUrl(config);
    expect(tenantBase).toBe("https://subrouter.example.com/t/srt_abcdef123456");
    expect(script).toContain("/etc/cmux/agent-routing.state");
    expect(script).toContain(agentRoutingStateToken(config));
    // The env file travels base64-encoded; decode every embedded payload and
    // check the actual in-VM writes.
    const payloads = decodedBase64Payloads(script);
    const envFile = payloads.find((p) => p.includes("ANTHROPIC_BASE_URL"));
    expect(envFile).toBeDefined();
    expect(envFile).toContain(`export ANTHROPIC_BASE_URL='${tenantBase}'`);
    expect(envFile).toContain(`export ANTHROPIC_AUTH_TOKEN='${config.subrouterTenantKey}'`);
    const python = payloads.find((p) => p.includes("openai_base_url"));
    expect(python).toBeDefined();
    expect(python).toContain(`TENANT_BASE = ${JSON.stringify(tenantBase)}`);
    expect(python).toContain('TENANT_BASE + "/v1"');
    expect(python).toContain('TENANT_BASE + "/backend-api"');
    // Every PTY session sources /etc/cmux/zshrc, which gains the managed block.
    expect(script).toContain("# >>> cmux-agent-routing >>>");
    expect(script).toContain("[ -r /etc/cmux/agent-env.sh ] && . /etc/cmux/agent-env.sh");
  });

  test("cleared config produces a removal script", () => {
    const script = buildAgentRoutingEnsureScript(null);
    expect(script).toContain("rm -f '/etc/cmux/agent-env.sh'");
    expect(script).toContain("sed -i");
    expect(script).toContain(agentRoutingStateToken(null));
    const python = decodedBase64Payloads(script).find((p) => p.includes("MODE"));
    expect(python).toBeDefined();
    expect(python).toContain('MODE = "remove"');
    // Removal must not re-introduce any tenant material.
    expect(script).not.toContain(config.subrouterTenantKey);
  });

  test("state token changes with the config so compare-and-skip reapplies", () => {
    expect(agentRoutingStateToken(config)).toBe(agentRoutingStateToken({ ...config }));
    expect(agentRoutingStateToken(config)).not.toBe(
      agentRoutingStateToken({ ...config, subrouterTenantKey: "srt_other_key_9" }),
    );
    expect(agentRoutingStateToken(config)).not.toBe(agentRoutingStateToken(null));
  });

  test("exec command is a single base64 pipeline that decodes to the script", () => {
    const command = agentRoutingEnsureCommand(config);
    const match = command.match(/^printf '%s' '([A-Za-z0-9+/=]+)' \| base64 -d \| sh$/);
    expect(match).not.toBeNull();
    const decoded = Buffer.from(match![1]!, "base64").toString("utf8");
    expect(decoded).toBe(buildAgentRoutingEnsureScript(config));
    // The raw tenant key rides inside the base64 payload only, never in the
    // plain-text command line.
    expect(command).not.toContain(config.subrouterTenantKey);
  });
});

const python3 = spawnSync("python3", ["--version"]).status === 0;
const mergeTest = python3 ? test : test.skip;

describe("codex/claude config merge behavior", () => {
  let home: string | null = null;

  afterEach(() => {
    if (home) rmSync(home, { recursive: true, force: true });
    home = null;
  });

  function runMerge(mergeConfig: AgentRoutingConfig | null): void {
    const result = spawnSync("python3", ["-"], {
      input: buildAgentRoutingMergeScript(mergeConfig),
      env: { ...process.env, CMUX_AGENT_ROUTING_HOME: home! },
      encoding: "utf8",
    });
    expect(result.status).toBe(0);
  }

  mergeTest("apply then remove preserves unrelated user content", () => {
    home = mkdtempSync(join(tmpdir(), "cmux-agent-routing-"));
    mkdirSync(join(home, ".codex"), { recursive: true });
    mkdirSync(join(home, ".claude"), { recursive: true });
    const userToml = [
      'openai_base_url = "https://old.example.com/v1"',
      'model = "gpt-5.2-codex"',
      "",
      "[mcp_servers.docs]",
      'command = "docs-server"',
      "",
    ].join("\n");
    writeFileSync(join(home, ".codex/config.toml"), userToml);
    writeFileSync(
      join(home, ".claude/settings.json"),
      JSON.stringify({ permissions: { allow: ["Bash"] }, env: { FOO: "bar" } }, null, 2),
    );

    runMerge(config);
    const tenantBase = subrouterTenantBaseUrl(config);
    const toml = readFileSync(join(home, ".codex/config.toml"), "utf8");
    // Managed block is prepended (top-level keys must precede table headers)
    // and the user's stale top-level assignment of a managed key is dropped.
    expect(toml.indexOf("cmux-agent-routing")).toBeLessThan(toml.indexOf("[mcp_servers.docs]"));
    expect(toml).toContain(`openai_base_url = "${tenantBase}/v1"`);
    expect(toml).toContain(`chatgpt_base_url = "${tenantBase}/backend-api"`);
    expect(toml).not.toContain("https://old.example.com/v1");
    expect(toml).toContain('model = "gpt-5.2-codex"');
    expect(toml).toContain("[mcp_servers.docs]");
    expect((toml.match(/^openai_base_url/gm) ?? []).length).toBe(1);

    const settings = JSON.parse(readFileSync(join(home, ".claude/settings.json"), "utf8"));
    expect(settings.env.ANTHROPIC_BASE_URL).toBe(tenantBase);
    expect(settings.env.ANTHROPIC_AUTH_TOKEN).toBe(config.subrouterTenantKey);
    expect(settings.env.FOO).toBe("bar");
    expect(settings.permissions).toEqual({ allow: ["Bash"] });

    // Re-apply is idempotent.
    runMerge(config);
    expect(readFileSync(join(home, ".codex/config.toml"), "utf8")).toBe(toml);

    runMerge(null);
    const removedToml = readFileSync(join(home, ".codex/config.toml"), "utf8");
    expect(removedToml).not.toContain("cmux-agent-routing");
    expect(removedToml).not.toContain("chatgpt_base_url");
    expect(removedToml).toContain('model = "gpt-5.2-codex"');
    expect(removedToml).toContain("[mcp_servers.docs]");
    const removedSettings = JSON.parse(readFileSync(join(home, ".claude/settings.json"), "utf8"));
    expect(removedSettings.env).toEqual({ FOO: "bar" });
    expect(removedSettings.permissions).toEqual({ allow: ["Bash"] });
  });

  mergeTest("apply creates fresh files and remove leaves missing files missing", () => {
    home = mkdtempSync(join(tmpdir(), "cmux-agent-routing-"));
    runMerge(config);
    expect(existsSync(join(home, ".codex/config.toml"))).toBe(true);
    expect(existsSync(join(home, ".claude/settings.json"))).toBe(true);
    const settings = JSON.parse(readFileSync(join(home, ".claude/settings.json"), "utf8"));
    expect(settings.env.ANTHROPIC_AUTH_TOKEN).toBe(config.subrouterTenantKey);

    rmSync(join(home, ".codex"), { recursive: true, force: true });
    rmSync(join(home, ".claude"), { recursive: true, force: true });
    runMerge(null);
    expect(existsSync(join(home, ".codex/config.toml"))).toBe(false);
    expect(existsSync(join(home, ".claude/settings.json"))).toBe(false);
  });

  mergeTest("unparseable claude settings are left untouched", () => {
    home = mkdtempSync(join(tmpdir(), "cmux-agent-routing-"));
    mkdirSync(join(home, ".claude"), { recursive: true });
    writeFileSync(join(home, ".claude/settings.json"), "{not json");
    runMerge(config);
    expect(readFileSync(join(home, ".claude/settings.json"), "utf8")).toBe("{not json");
  });
});

function decodedBase64Payloads(script: string): string[] {
  return [...script.matchAll(/printf '%s' '([A-Za-z0-9+/=]+)' \| base64 -d/g)].map((match) =>
    Buffer.from(match[1]!, "base64").toString("utf8"),
  );
}
