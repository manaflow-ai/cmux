import { describe, expect, test } from "bun:test";
import { fileURLToPath } from "node:url";
import bundled from "./cmuxIcons.json";
import custom from "./cmuxIconsCustom.json";
import neko from "./cmuxIconsNeko.json";
import { customIconPack, nekoFillInIconPack, nekoIconPack, overlaidIconPack } from "./iconPack";
import type { IconPack } from "./types";

const repoRoot = fileURLToPath(new URL("../../../../../", import.meta.url));

describe("icon pack", () => {
  // The pack, the native catalog and the Swift names are generated from design/icons/source.
  test("generated outputs match the sources", () => {
    const run = Bun.spawnSync(["python3", "scripts/icons/build_pack.py", "--check"], { cwd: repoRoot });
    expect(run.stderr.toString() + run.stdout.toString()).toBe("");
    expect(run.exitCode).toBe(0);
  });

  // Debug Settings icons.family = custom (Lucas 2026-10-17): the custom family redraws names the pack has.
  test("the custom family overlays names the pack already has", () => {
    const pack = bundled as IconPack;
    const overlay = custom as IconPack;
    const names = Object.keys(overlay.icons);
    expect(names).toContain("agent.chat");
    expect(names).toContain("store");
    for (const name of names) expect(Object.hasOwn(pack.icons, name)).toBe(true);
    const merged = overlaidIconPack(pack, overlay);
    expect(merged.icons.store).toEqual(overlay.icons.store);
    expect(merged.icons["tab.close"]).toEqual(pack.icons["tab.close"]);
    expect(customIconPack.icons["agent.chat"]).toEqual(overlay.icons["agent.chat"]);
  });

  test("the Neko family stays a conservative overlay", () => {
    const pack = bundled as IconPack;
    const overlay = neko as IconPack;
    const names = Object.keys(overlay.icons);
    expect(names.length).toBe(40);
    expect(names).toContain("action.copy");
    expect(names).toContain("action.pin");
    expect(names).toContain("agent.chat");
    expect(names).not.toContain("status.running");
    for (const name of names) expect(Object.hasOwn(pack.icons, name)).toBe(true);
    expect(nekoIconPack.icons["action.copy"]).toEqual(overlay.icons["action.copy"]);
    expect(nekoIconPack.icons["action.more"]).toEqual(pack.icons["action.more"]);
  });

  test("the gallery fill-in candidate does not imply a full theme", () => {
    expect(Object.keys(nekoFillInIconPack.icons)).toEqual(Object.keys(bundledIconPack.icons));
    expect(nekoFillInIconPack.icons["action.copy"]).toEqual(neko.icons["action.copy"]);
    expect(nekoFillInIconPack.icons["action.pin"]).toEqual(neko.icons["action.pin"]);
    expect(nekoFillInIconPack.icons["agent.chat"]).toEqual(bundled.icons["agent.chat"]);
  });
});
