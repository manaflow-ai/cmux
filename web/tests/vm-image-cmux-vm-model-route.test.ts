// The NEXT Cloud image routes every agent's model calls through the machine's coderouter edge
// (coderouter.cmux.internal): the edge injects the per-machine token, so the guest holds only the public
// placeholder and never a provider login. acpmux starts Claude Code and Codex from the login environment,
// where agent-config.sh keeps Claude's pair set aside, so the route is pinned in each agent's managed
// (root-owned, highest precedence) settings, which outrank any login a user or an old copy left in HOME.
import { describe, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import * as bake from "../scripts/cmux-vm-image/bake";
import { VM_PLACEHOLDER_API_KEY } from "../services/coderouter/vmGuestEnv";
import { runChild } from "./helpers/run-child";

const ORIGIN = "https://coderouter.cmux.internal";
const CREDENTIAL = /sk-ant-|sk-proj-|crt_|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.|CLAUDE_CODE_OAUTH_TOKEN|refresh_token|access_token/;

describe("cmux VM image model route", () => {
  test("Claude Code's managed settings send every request to the edge with the placeholder key", async () => {
    const files = bake.agentModelRouteFiles();
    const claude = files.find((f) => f.target === "/etc/claude-code/managed-settings.json");
    expect(claude).toBeDefined();
    const settings = JSON.parse(claude!.text) as { env?: Record<string, string>; apiKeyHelper?: string; skipDangerousModePermissionPrompt?: boolean };
    expect(settings.env?.ANTHROPIC_BASE_URL).toBe(ORIGIN);
    // No env key outranks the helper with a real credential, and the helper prints only the placeholder.
    expect(Object.keys(settings.env ?? {}).filter((k) => /KEY|TOKEN/.test(k))).toEqual([]);
    const helper = await runChild("sh", ["-c", settings.apiKeyHelper!], { timeout: 10_000, env: { PATH: "/usr/bin:/bin" } });
    expect(helper.status).toBe(0);
    expect(helper.stdout).toBe(VM_PLACEHOLDER_API_KEY);
    // The image's existing managed defaults stay.
    expect(settings.skipDangerousModePermissionPrompt).toBe(true);
    expect(claude!.mode).toBe(0o644);
  });

  test("Codex's managed config selects the edge provider over any user config or auth.json", () => {
    const codex = bake.agentModelRouteFiles().find((f) => f.target === "/etc/codex/managed_config.toml");
    expect(codex).toBeDefined();
    const config = Bun.TOML.parse(codex!.text) as {
      model_provider?: string;
      model_providers?: Record<string, { base_url?: string; env_key?: string; requires_openai_auth?: boolean; wire_api?: string; supports_websockets?: boolean }>;
      projects?: Record<string, { trust_level?: string }>;
      check_for_update_on_startup?: boolean;
    };
    expect(config.model_provider).toBe("cmux");
    const provider = config.model_providers?.cmux;
    expect(provider?.base_url).toBe(`${ORIGIN}/v1`);
    expect(provider?.requires_openai_auth).toBe(false);
    expect(provider?.env_key).toBe("OPENAI_API_KEY");
    expect(provider?.wire_api).toBe("responses");
    expect(provider?.supports_websockets).toBe(false);
    // The folder trust the old managed file carried stays.
    expect(config.projects?.["/home/cmux"]?.trust_level).toBe("trusted");
    expect(config.check_for_update_on_startup).toBe(false);
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
        mkdirSync(path.dirname(path.join(root, bake.AGENT_MODEL_ROUTE_SYNC_PATH)), { recursive: true });
        writeFileSync(path.join(root, bake.AGENT_MODEL_ROUTE_SYNC_PATH), bake.agentModelRouteSyncScript());
      };
      write();
      const ok = await runChild("sh", ["-c", bake.agentModelRouteCheckCommand(root)], { timeout: 20_000 });
      expect(ok.stderr).toBe("");
      expect(ok.stdout).toBe("agent-model-route-baked\n");
      // Baked in place, the route reached staging and production machines that have no edge (cmux-platform#1442).
      mkdirSync(path.join(root, "etc/claude-code"), { recursive: true });
      writeFileSync(path.join(root, "etc/claude-code/managed-settings.json"), bake.agentModelRouteFiles()[0]!.text);
      const inPlace = await runChild("sh", ["-c", bake.agentModelRouteCheckCommand(root)], { timeout: 20_000 });
      expect(inPlace.status).not.toBe(0);
      rmSync(path.join(root, "etc/claude-code/managed-settings.json"));
      write("\n# CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-x\n");
      const planted = await runChild("sh", ["-c", bake.agentModelRouteCheckCommand(root)], { timeout: 20_000 });
      expect(planted.status).not.toBe(0);
      rmSync(path.join(root, bake.AGENT_MODEL_ROUTE_DIR, "claude-managed-settings.json"));
      write();
      rmSync(path.join(root, bake.AGENT_MODEL_ROUTE_DIR, "codex-managed_config.toml"));
      const missing = await runChild("sh", ["-c", bake.agentModelRouteCheckCommand(root)], { timeout: 20_000 });
      expect(missing.status).not.toBe(0);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  // cmux-platform#1442: one snapshot boots in the dev pool, staging and production, and only the dev pool's
  // machines get the coderouter edge rule. The route baked in place sent every staging and production Claude chat
  // to a name that does not resolve (ENOTFOUND after about 180 s).
  test("a machine whose edge alias does not resolve gets no managed route; one whose alias resolves gets it", async () => {
    const root = mkdtempSync(path.join(os.tmpdir(), "cmux-vm-model-route-sync-"));
    const stub = mkdtempSync(path.join(os.tmpdir(), "cmux-vm-model-route-getent-"));
    const at = (p: string) => path.join(root, p);
    const exists = (p: string) => Bun.file(at(p)).size > 0;
    try {
      // What the bake writes.
      for (const file of [...bake.agentModelRouteFiles(), { path: bake.AGENT_MODEL_ROUTE_SYNC_PATH, text: bake.agentModelRouteSyncScript(), mode: 0o755 }]) {
        mkdirSync(path.dirname(at(file.path)), { recursive: true });
        writeFileSync(at(file.path), file.text, { mode: file.mode });
      }
      const pass = async (resolves: boolean) => {
        writeFileSync(path.join(stub, "getent"), `#!/bin/sh\nexit ${resolves ? 0 : 2}\n`, { mode: 0o755 });
        const run = await runChild("sh", [at(bake.AGENT_MODEL_ROUTE_SYNC_PATH)], {
          timeout: 20_000,
          env: { PATH: `${stub}:/usr/bin:/bin`, CMUX_AGENT_MODEL_ROUTE_ROOT: root },
        });
        expect(run.stderr).toBe("");
        expect(run.status).toBe(0);
      };
      const managed = ["/etc/claude-code/managed-settings.json", "/etc/codex/managed_config.toml"];

      // A staging or production machine: nothing in the agents' managed paths.
      await pass(false);
      for (const p of managed) expect(exists(p)).toBe(false);

      // A dev pool machine: both route files, byte for byte.
      await pass(true);
      for (const file of bake.agentModelRouteFiles()) {
        expect(await Bun.file(at(file.target)).text()).toBe(file.text);
      }

      // The edge goes away: the route goes with it, but a managed file someone else wrote stays.
      writeFileSync(at("/etc/codex/managed_config.toml"), "# an operator's own\n");
      await pass(false);
      expect(exists("/etc/claude-code/managed-settings.json")).toBe(false);
      expect(await Bun.file(at("/etc/codex/managed_config.toml")).text()).toBe("# an operator's own\n");
    } finally {
      rmSync(root, { recursive: true, force: true });
      rmSync(stub, { recursive: true, force: true });
    }
  });
});
