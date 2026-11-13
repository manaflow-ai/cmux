// The NEXT Cloud image routes every agent's model calls through the machine's coderouter edge
// (coderouter.cmux.internal) by default: the edge injects the per-machine token, so the guest holds only the
// public placeholder. The route is a default, never a pin: a chat the owner's Mac starts on the owner's own
// connection (cmux-tui/docs/model-connections.md, Revision 2) runs straight to its provider through the env and
// `-c` overrides acpmux gives that agent, so no managed layer (which outranks both) may carry the route.
import { describe, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import * as bake from "../scripts/cmux-vm-image/bake";
import { runChild } from "./helpers/run-child";

const ORIGIN = "https://coderouter.cmux.internal";
const CREDENTIAL = /sk-ant-|sk-proj-|crt_|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.|CLAUDE_CODE_OAUTH_TOKEN|refresh_token|access_token/;

describe("cmux VM image model route", () => {
  test("Claude Code's managed settings carry no route, helper or key", () => {
    const claude = bake.agentModelRouteFiles().find((f) => f.path === "/etc/claude-code/managed-settings.json");
    expect(claude).toBeDefined();
    const settings = JSON.parse(claude!.text) as Record<string, unknown>;
    // A managed env or apiKeyHelper outranks CLAUDE_CODE_OAUTH_TOKEN and would send an owner's key to the edge.
    expect(settings.env).toBeUndefined();
    expect(settings.apiKeyHelper).toBeUndefined();
    // The image's managed defaults stay.
    expect(settings).toEqual({ cleanupPeriodDays: 99999, skipDangerousModePermissionPrompt: true });
    expect(claude!.mode).toBe(0o644);
  });

  test("Codex's edge provider is the system default, below the user config and -c; the managed file pins none", () => {
    const files = bake.agentModelRouteFiles();
    const system = files.find((f) => f.path === "/etc/codex/config.toml");
    const managed = files.find((f) => f.path === "/etc/codex/managed_config.toml");
    expect(system).toBeDefined();
    expect(managed).toBeDefined();
    const config = Bun.TOML.parse(system!.text) as {
      model_provider?: string;
      model_providers?: Record<string, { base_url?: string; env_key?: string; requires_openai_auth?: boolean; wire_api?: string; supports_websockets?: boolean }>;
    };
    expect(config.model_provider).toBe("cmux");
    const provider = config.model_providers?.cmux;
    expect(provider?.base_url).toBe(`${ORIGIN}/v1`);
    expect(provider?.requires_openai_auth).toBe(false);
    expect(provider?.env_key).toBe("OPENAI_API_KEY");
    expect(provider?.wire_api).toBe("responses");
    expect(provider?.supports_websockets).toBe(false);
    const pinned = Bun.TOML.parse(managed!.text) as {
      model_provider?: string;
      model_providers?: unknown;
      projects?: Record<string, { trust_level?: string }>;
      check_for_update_on_startup?: boolean;
    };
    // The legacy managed layer outranks `-c` (codex-rs ConfigLayerSource::precedence): no provider there.
    expect(pinned.model_provider).toBeUndefined();
    expect(pinned.model_providers).toBeUndefined();
    // The folder trust and update switch it carried stay.
    expect(pinned.projects?.["/home/cmux"]?.trust_level).toBe("trusted");
    expect(pinned.projects?.["/root"]?.trust_level).toBe("trusted");
    expect(pinned.check_for_update_on_startup).toBe(false);
  });

  test("no route file carries a credential", () => {
    for (const file of bake.agentModelRouteFiles()) expect(file.text).not.toMatch(CREDENTIAL);
  });

  test("the bake's check passes on the written files and fails when a login is planted in them", async () => {
    const root = mkdtempSync(path.join(os.tmpdir(), "cmux-vm-model-route-"));
    try {
      const write = (extra = "") => {
        for (const file of bake.agentModelRouteFiles()) {
          mkdirSync(path.dirname(path.join(root, file.path)), { recursive: true });
          writeFileSync(path.join(root, file.path), file.text + extra);
        }
      };
      write();
      const ok = await runChild("sh", ["-c", bake.agentModelRouteCheckCommand(root)], { timeout: 20_000 });
      expect(ok.stderr).toBe("");
      expect(ok.stdout).toBe("agent-model-route-baked\n");
      write("\n# CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-x\n");
      const planted = await runChild("sh", ["-c", bake.agentModelRouteCheckCommand(root)], { timeout: 20_000 });
      expect(planted.status).not.toBe(0);
      // A route pinned in a managed layer again (an older bake) fails the check.
      for (const [file, text] of [
        ["etc/claude-code/managed-settings.json", JSON.stringify({ apiKeyHelper: "printf %s x" })],
        ["etc/claude-code/managed-settings.json", JSON.stringify({ env: { ANTHROPIC_BASE_URL: ORIGIN } })],
        ["etc/codex/managed_config.toml", 'model_provider = "cmux"\n'],
      ]) {
        write();
        writeFileSync(path.join(root, file), text);
        const pinned = await runChild("sh", ["-c", bake.agentModelRouteCheckCommand(root)], { timeout: 20_000 });
        expect(pinned.status).not.toBe(0);
      }
      rmSync(path.join(root, "etc/claude-code/managed-settings.json"));
      write();
      rmSync(path.join(root, "etc/codex/managed_config.toml"));
      const missing = await runChild("sh", ["-c", bake.agentModelRouteCheckCommand(root)], { timeout: 20_000 });
      expect(missing.status).not.toBe(0);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});
