import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { bakeOptionsFromArgv, layerFlags } from "../scripts/cmux-vm-image/bake";
import { DEFAULT_LOCK_PATH } from "../scripts/cmux-vm-image/lock";
import {
  agentProgramsText,
  baseInputTree,
  cachedInstallCommand,
  isBaseInput,
  layerKeys,
  layerName,
  overlayPrepareCommand,
  overlayPruneCommand,
  systemLockText,
} from "../scripts/cmux-vm-image/layers";
import { runChild } from "./helpers/run-child";

const lockText = readFileSync(DEFAULT_LOCK_PATH, "utf8");
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

/** The lock with one program's sha256 changed (a new pin of that program). */
function repin(name: string): string {
  const lock = JSON.parse(lockText) as { programs: Array<{ name: string; sha256: string }> };
  for (const p of lock.programs) if (p.name === name) p.sha256 = "f".repeat(64);
  return JSON.stringify(lock, null, 2);
}

async function bashSyntax(script: string): Promise<void> {
  const result = await runChild("bash", ["-n"], { input: script, timeout: 20_000 });
  expect(result.stderr).toBe("");
  expect(result.status).toBe(0);
}

describe("layered bake keys", () => {
  const keys = layerKeys(lockText, [], "tree");

  test("a cmux-tui pin changes no cached layer", () => {
    expect(layerKeys(repin("cmux-tui"), [], "tree")).toEqual(keys);
    expect(layerKeys(repin("cmux-tui-hook"), [], "tree")).toEqual(keys);
  });

  test("an agent pin rebuilds agents only", () => {
    const next = layerKeys(repin("claude"), [], "tree");
    expect(next.system).toBe(keys.system);
    expect(next.agents).not.toBe(keys.agents);
  });

  test("an apt change, a flag or a bake source rebuilds both", () => {
    const lock = JSON.parse(lockText) as { base: { snapshot: string } };
    lock.base.snapshot = "sc-other";
    for (const next of [layerKeys(JSON.stringify(lock), [], "tree"), layerKeys(lockText, ["agent-tools"], "tree"), layerKeys(lockText, [], "tree2")]) {
      expect(next.system).not.toBe(keys.system);
      expect(next.agents).not.toBe(keys.agents);
    }
  });

  test("key order and flag order do not matter", () => {
    const reordered = JSON.stringify(Object.fromEntries(Object.entries(JSON.parse(lockText) as object).reverse()));
    expect(layerKeys(reordered, ["team-vm", "agent-tools"], "tree")).toEqual(layerKeys(lockText, ["agent-tools", "team-vm"], "tree"));
  });

  test("the system lock has no programs; the agents text has none of the app's", () => {
    expect(systemLockText(lockText)).toContain('"programs":[]');
    expect(agentProgramsText(lockText)).not.toContain('"name":"cmux-tui"');
    expect(agentProgramsText(lockText)).toContain('"name":"claude"');
  });

  test("names fit the dev prefix and the 41-character tag limit", () => {
    for (const layer of ["system", "agents"] as const) {
      const name = layerName(layer, keys[layer]);
      expect(name).toMatch(/^cmuxnp-dev-vmimg-[a-z0-9-]{1,41}$/);
    }
  });

  test("the input tree reads git blobs and drops the lock, channels, docs and tests", () => {
    expect(isBaseInput("images/cmux-vm/inputs.lock.json")).toBe(false);
    expect(isBaseInput("images/cmux-vm/channels/dev.json")).toBe(false);
    expect(isBaseInput("web/scripts/cmux-vm-image/README.md")).toBe(false);
    expect(isBaseInput("web/scripts/cmux-vm-image/bake.ts")).toBe(true);
    const tree = baseInputTree(repoRoot);
    expect(tree).toContain("web/scripts/cmux-vm-image/bake.ts");
    expect(tree).not.toContain("inputs.lock.json");
  });

  test("flags come from the options; --layered refuses promotion, production copies and the dev tree", () => {
    expect(layerFlags(bakeOptionsFromArgv(["bun", "bake.ts", "--tag", "t", "--agent-tools", "--layered"]))).toEqual(["agent-tools"]);
    expect(bakeOptionsFromArgv(["bun", "bake.ts", "--tag", "t", "--layered"]).layered).toBe(true);
    for (const extra of ["--promotion", "--prod-copy", "--update-lock", "--dev-tree"]) {
      expect(() => bakeOptionsFromArgv(["bun", "bake.ts", "--tag", "t", "--layered", extra])).toThrow();
    }
  });
});

describe("overlay commands", () => {
  test("parse", async () => {
    await bashSyntax(overlayPrepareCommand(["cmux-tui", "cmux-tui-hook"]));
    await bashSyntax(overlayPruneCommand());
    await bashSyntax(cachedInstallCommand("/opt/cmux/store/abc", "echo install", "x"));
  });

  test("prepare stops self-update during the bake and restores the live apt sources finalize expects", () => {
    const prepare = overlayPrepareCommand(["claude"]);
    expect(prepare).toContain("touch /etc/cmux/no-self-update");
    expect(prepare).toContain("/etc/apt/ubuntu.sources.live");
  });
});

describe("per-user layer inventory", () => {
  test("the image baseline and the additions diff parse, and the diff reads names only", async () => {
    const { imagePackagesCommand, userAdditionsCommand, IMAGE_PACKAGES_PATH } = await import("../scripts/cmux-vm-image/layers");
    await bashSyntax(imagePackagesCommand());
    await bashSyntax(userAdditionsCommand());
    expect(userAdditionsCommand()).toContain(`comm -13 ${IMAGE_PACKAGES_PATH} -`);
    expect(userAdditionsCommand()).not.toMatch(/Version|history|argv/);
  });
});

describe("layer snapshot GC", () => {
  const at = (h: number) => new Date(Date.UTC(2026, 10, 1) + h * 3600_000).toISOString();
  const now = Date.UTC(2026, 10, 3);
  const sys = (n: number, h: number) => ({ id: `sh-sys${n}`, slug: `cmuxnp-dev-vmimg-sys-${n}`, displayName: `cmuxnp-dev-vmimg-sys-${n} from sc-base`, createdAt: at(h) });
  const agt = (n: number, h: number, parent: string, label = true) => ({ id: `sh-agt${n}`, slug: `cmuxnp-dev-vmimg-agt-${n}`, displayName: label ? `cmuxnp-dev-vmimg-agt-${n} from ${parent}` : `cmuxnp-dev-vmimg-agt-${n}`, createdAt: at(h) });

  test("keeps the newest per layer, referenced images and their whole chain; deletes only layers", async () => {
    const { planLayerGc } = await import("../scripts/cmux-vm-image/gc-layers");
    const all = [
      sys(1, 1), sys(2, 2), sys(3, 3),
      agt(1, 1, "sh-sys1"), agt(2, 2, "sh-sys2"), agt(3, 3, "sh-sys3"),
      { id: "sh-app1", slug: "cmuxnp-dev-vmimg-ci-1", displayName: "cmuxnp-dev-vmimg-ci-1 from sh-agt1", createdAt: at(1) },
      { id: "sh-other", slug: "cmuxnp-dev-vmimg-ci-0", displayName: "cmuxnp-dev-vmimg-ci-0", createdAt: at(0) },
    ];
    const plan = planLayerGc(all, new Set(["sh-app1"]), { keep: 1, recentMs: 0, now });
    expect(plan.keep.get("sh-sys3")).toBe("newest 1 of system");
    expect(plan.keep.has("sh-agt1")).toBe(true);
    expect(plan.keep.has("sh-sys1")).toBe(true);
    expect(plan.remove.map((s) => s.id).sort()).toEqual(["sh-agt2", "sh-sys2"]);
  });

  test("an image still on the account keeps its layers even when no file names it", async () => {
    const { planLayerGc } = await import("../scripts/cmux-vm-image/gc-layers");
    const all = [sys(1, 1), sys(2, 2), agt(1, 1, "sh-sys1"), agt(2, 2, "sh-sys2"), { id: "sh-app", slug: "cmuxnp-dev-vmimg-ci-9", displayName: "cmuxnp-dev-vmimg-ci-9 from sh-agt1", createdAt: at(1) }];
    expect(planLayerGc(all, new Set(), { keep: 1, recentMs: 0, now }).remove).toEqual([]);
  });

  test("an agents layer without a recorded parent keeps every system layer", async () => {
    const { planLayerGc } = await import("../scripts/cmux-vm-image/gc-layers");
    const all = [sys(1, 1), sys(2, 2), agt(1, 2, "", false)];
    expect(planLayerGc(all, new Set(), { keep: 1, recentMs: 0, now }).remove).toEqual([]);
  });

  test("a recently booted layer stays", async () => {
    const { planLayerGc } = await import("../scripts/cmux-vm-image/gc-layers");
    const all = [sys(1, 1), { ...sys(2, 2), lastUsedAt: new Date(now - 60_000).toISOString() }, sys(3, 3)];
    expect(planLayerGc(all, new Set(), { keep: 1, recentMs: 3600_000, now }).remove.map((s) => s.id)).toEqual(["sh-sys1"]);
  });
});

describe("deferred inventory", () => {
  test("--defer-inventory needs --layered; prod copies drop the build-only flags", async () => {
    expect(() => bakeOptionsFromArgv(["bun", "bake.ts", "--tag", "t", "--defer-inventory"])).toThrow();
    expect(bakeOptionsFromArgv(["bun", "bake.ts", "--tag", "t", "--layered", "--defer-inventory"]).deferInventory).toBe(true);
    const { recordedFlags } = await import("../scripts/cmux-vm-image/prod-copy");
    expect(recordedFlags("images/cmux-vm/bake.ts --agent-tools --layered --defer-inventory (CI run 7)")).toEqual(["--agent-tools", "--layered", "--defer-inventory"]);
  });
});
