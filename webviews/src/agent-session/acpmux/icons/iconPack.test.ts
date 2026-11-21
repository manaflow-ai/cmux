import { describe, expect, test } from "bun:test";
import { fileURLToPath } from "node:url";
import bundled from "./cmuxIcons.json";
import custom from "./cmuxIconsCustom.json";
import neko from "./nekoCandidate.json";
import rounds from "./nekoRounds.json";
import { customIconPack, overlaidIconPack } from "./iconPack";
import type { IconPack } from "./types";

const repoRoot = fileURLToPath(new URL("../../../../../", import.meta.url));

describe("icon pack", () => {
  // The pack, the native catalog and the Swift names are generated from design/icons/source.
  test("generated outputs match the sources", () => {
    const run = Bun.spawnSync(["python3", "scripts/icons/build_pack.py", "--check"], {
      cwd: repoRoot,
    });
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

  test("the gallery candidate preserves semantic status and privacy marks", () => {
    const pack = bundled as IconPack;
    const overlay = neko as IconPack;
    const names = Object.keys(overlay.icons);
    expect(names.length).toBe(37);
    expect(names).toContain("action.copy");
    expect(names).toContain("action.pin");
    expect(names).toContain("agent.chat");
    expect(names).not.toContain("status.running");
    expect(names).not.toContain("state.idle");
    expect(names).not.toContain("browser.incognito");
    for (const name of names) expect(Object.hasOwn(pack.icons, name)).toBe(true);
    const merged = overlaidIconPack(pack, overlay);
    expect(merged.icons["action.copy"]).toEqual(overlay.icons["action.copy"]);
    expect(merged.icons["action.more"]).toEqual(pack.icons["action.more"]);
  });

  // The gallery draws art-round directions through the shared renderer, so each must be a pack overlay
  // of existing names at the pack's 1.5 grid stroke, not a file the renderer cannot normalize.
  test("art-round directions are overlays of pack names at the pack stroke", () => {
    const pack = bundled as IconPack;
    const six = ["action.copy", "action.retry", "media.audio", "bookmark", "action.pin", "action.more"];
    const directions = rounds as Record<string, IconPack>;
    expect(Object.keys(directions).sort()).toEqual(["earfold", "r3mix", "r3tail", "tailterm", "whisker"]);
    for (const [direction, overlay] of Object.entries(directions)) {
      const names = Object.keys(overlay.icons);
      for (const name of names) {
        expect(six).toContain(name);
        expect(Object.hasOwn(pack.icons, name)).toBe(true);
        for (const layer of overlay.icons[name].line) {
          expect(layer.accent).toBeUndefined();
          if (layer.op === "stroke") expect(layer.w).toBe(1.5);
        }
      }
      expect(names.length).toBe(direction.startsWith("r3") ? 6 : 3);
    }
  });
});
