import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
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
const repoRoot = path.resolve(import.meta.dir, "../..");

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
