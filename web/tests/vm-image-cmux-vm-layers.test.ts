import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { bakeOptionsFromArgv, layerFlags } from "../scripts/cmux-vm-image/bake";
import { DEFAULT_LOCK_PATH } from "../scripts/cmux-vm-image/lock";
import {
  agentProgramsText,
  baseInputTree,
  bakeScriptClosure,
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

  test("an image script is an input only when the bake runs it; the smoke, GC and probes are not", () => {
    const read = (file: string) => {
      try {
        return readFileSync(path.join(repoRoot, file), "utf8");
      } catch {
        return undefined;
      }
    };
    const scripts = bakeScriptClosure(read);
    for (const f of ["bake.ts", "lock.ts", "layers.ts", "dev-tree.ts", "sshd.ts", "host-agent.ts", "browser-probe.ts", "apt-update.ts", "dns.ts"]) {
      expect(scripts.has(`web/scripts/cmux-vm-image/${f}`)).toBe(true);
    }
    for (const f of ["smoke.ts", "gc-layers.ts", "inventory.ts", "first-session.ts", "cleanup.ts", "daemon-uptime.ts", "repro.ts"]) {
      expect(scripts.has(`web/scripts/cmux-vm-image/${f}`)).toBe(false);
      expect(isBaseInput(`web/scripts/cmux-vm-image/${f}`, scripts)).toBe(false);
    }
    expect(isBaseInput("images/cmux-vm/bake.ts", scripts)).toBe(true);
    expect(isBaseInput("images/cmux-vm/smoke.ts", scripts)).toBe(false);
    // Guest files, other trees and non-script files stay inputs whatever the closure says.
    expect(isBaseInput("images/cmux-vm/guest/sampler.py", scripts)).toBe(true);
    expect(isBaseInput("web/scripts/cmux-vm-image/acpmux_person_key_e2e.py", scripts)).toBe(true);
    expect(isBaseInput("web/services/vms/images/workUser.ts", scripts)).toBe(true);
    expect(isBaseInput("web/scripts/cmux-vm-image/smoke.ts")).toBe(true);
    const tree = baseInputTree(repoRoot);
    expect(tree).toContain("web/scripts/cmux-vm-image/sshd.ts");
    expect(tree).not.toContain("web/scripts/cmux-vm-image/smoke.ts");
    expect(tree).not.toContain("web/scripts/cmux-vm-image/gc-layers.ts");
  });

  test("the closure follows re-exports and dynamic imports", () => {
    const files: Record<string, string> = {
      "web/scripts/cmux-vm-image/bake.ts": 'import { a } from "./a";\nexport { b } from "./b.ts";\nconst c = await import("./c");',
      "web/scripts/cmux-vm-image/a.ts": "import { d } from './d';\nimport \"./e\";\nimport f from \"./f.js\";\nimport type { G } from \"./g.ts\";",
    };
    const scripts = bakeScriptClosure((f) => files[f]);
    expect([...scripts].sort()).toEqual(["images/cmux-vm/bake.ts", ...["a", "b", "bake", "c", "d", "e", "f", "g"].map((x) => `web/scripts/cmux-vm-image/${x}.ts`)]);
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
  const key = (c: string) => c.repeat(16);
  const sys = (c: string, h: number) => ({ id: `sh-sys${c}`, slug: `cmuxnp-dev-vmimg-sys-${key(c)}`, displayName: `cmuxnp-dev-vmimg-sys-${key(c)}`, createdAt: at(h), lastUsedAt: at(h) });
  const agt = (c: string, h: number, sysC?: string) => ({ id: `sh-agt${c}`, slug: `cmuxnp-dev-vmimg-agt-${key(c)}`, displayName: sysC ? `cmuxnp-dev-vmimg-agt-${key(c)} ^sys-${key(sysC)}` : `cmuxnp-dev-vmimg-agt-${key(c)}`, createdAt: at(h), lastUsedAt: at(h) });
  const app = (n: number, h: number, agtC?: string) => ({ id: `sh-app${n}`, slug: `cmuxnp-dev-vmimg-ci-${n}-1`, displayName: agtC ? `cmuxnp-dev-vmimg-ci-${n}-1 ^agt-${key(agtC)}` : `cmuxnp-dev-vmimg-ci-${n}-1`, createdAt: at(h) });

  test("a label names the parent layer and fits 64 characters; a provider parent gives the bare name", async () => {
    const { layerLabel, labelParent, LABEL_MAX } = await import("../scripts/cmux-vm-image/layers");
    const label = layerLabel("cmuxnp-dev-vmimg-ci-team-42014180836-12", `cmuxnp-dev-vmimg-agt-${key("a")}`);
    expect(label.length).toBeLessThanOrEqual(LABEL_MAX);
    expect(labelParent(label)).toBe(`cmuxnp-dev-vmimg-agt-${key("a")}`);
    expect(layerLabel(`cmuxnp-dev-vmimg-agt-${key("a")}`, `cmuxnp-dev-vmimg-sys-${key("b")}`).length).toBeLessThanOrEqual(LABEL_MAX);
    expect(layerLabel(`cmuxnp-dev-vmimg-sys-${key("b")}`, "sc-provider-base")).toBe(`cmuxnp-dev-vmimg-sys-${key("b")}`);
    expect(layerLabel(`cmuxnp-dev-vmimg-${"x".repeat(41)}`, `cmuxnp-dev-vmimg-agt-${key("a")}`)).toBe(`cmuxnp-dev-vmimg-${"x".repeat(41)}`);
  });

  test("keeps the newest per layer and every labeled chain under a live image; deletes the rest of the layers", async () => {
    const { planLayerGc } = await import("../scripts/cmux-vm-image/gc-layers");
    const all = [sys("1", 1), sys("2", 2), sys("3", 3), agt("4", 1, "1"), agt("5", 2, "2"), agt("6", 3, "3"), app(1, 1.5, "4")];
    const plan = planLayerGc(all, new Set(), { keep: 1, recentMs: 0, now });
    expect(plan.keep.get("sh-sys3")).toBe("newest 1 of system");
    expect(plan.keep.has("sh-agt4") && plan.keep.has("sh-sys1")).toBe(true);
    expect(plan.remove.map((s) => s.id).sort()).toEqual(["sh-agt5", "sh-sys2"]);
  });

  test("an image or overlay with no recorded parent keeps every layer older than itself", async () => {
    const { planLayerGc } = await import("../scripts/cmux-vm-image/gc-layers");
    const all = [sys("1", 1), sys("2", 2), agt("4", 1.5), agt("5", 2.5, "2"), sys("3", 4), agt("6", 4, "3"), app(1, 3)];
    const plan = planLayerGc(all, new Set(), { keep: 1, recentMs: 0, now });
    expect(plan.remove).toEqual([]);
    const later = planLayerGc([sys("1", 1), sys("2", 2), sys("3", 3), app(2, 0.5)], new Set(), { keep: 1, recentMs: 0, now });
    expect(later.remove.map((s) => s.id).sort()).toEqual(["sh-sys1", "sh-sys2"]);
  });

  test("a layer made inside the window stays though its last boot is older", async () => {
    const { planLayerGc } = await import("../scripts/cmux-vm-image/gc-layers");
    // The newest is kept as newest; the second newest stays only because it was made inside the window.
    const fresh = { ...sys("9", 0), createdAt: new Date(now - 120_000).toISOString() };
    const newest = { ...sys("2", 0), createdAt: new Date(now - 60_000).toISOString() };
    const all = [sys("1", 1), fresh, newest];
    expect(planLayerGc(all, new Set(), { keep: 1, recentMs: 3600_000, now }).remove.map((s) => s.id)).toEqual(["sh-sys1"]);
  });

  test("a layer whose last boot the list does not say stays a week after it was made", async () => {
    const { planLayerGc, UNKNOWN_USE_MS } = await import("../scripts/cmux-vm-image/gc-layers");
    const made = (c: string, ago: number) => ({ ...sys(c, 0), createdAt: new Date(now - ago).toISOString(), lastUsedAt: undefined });
    const all = [made("1", UNKNOWN_USE_MS + 3600_000), made("2", UNKNOWN_USE_MS - 3600_000), made("3", 60_000)];
    const plan = planLayerGc(all, new Set(), { keep: 1, recentMs: 3600_000, now });
    expect(plan.keep.get("sh-sys2")).toBe("last boot unknown, made recently");
    expect(plan.remove.map((s) => s.id)).toEqual(["sh-sys1"]);
  });

  test("a referenced snapshot and a recently booted layer stay", async () => {
    const { planLayerGc } = await import("../scripts/cmux-vm-image/gc-layers");
    const all = [sys("1", 1), { ...sys("2", 2), lastUsedAt: new Date(now - 60_000).toISOString() }, sys("3", 3), sys("4", 4)];
    expect(planLayerGc(all, new Set([`cmuxnp-dev-vmimg-sys-${key("1")}`]), { keep: 1, recentMs: 3600_000, now }).remove.map((s) => s.id)).toEqual(["sh-sys3"]);
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
