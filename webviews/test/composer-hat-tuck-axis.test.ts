// The open hat's tuck control stands on the hat's own axis (Leo, 2026-11-24: "actually this looks bad.
// tuck and its appearnace... maybe in the middle again? ... you guys need to be aligning things better
// and thinking about the math and logic and design constraints better"). Beside the header's split icon
// and chevron it sat on none of their lines. The tucked pill steps aside for Jump to latest
// (jumpPlace.ts `hatSide`); this control does not follow it, it keeps the person's setting.
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";

const src = (file: string) => readFileSync(path.resolve(import.meta.dir, "../src", file), "utf8");

describe("the open hat's tuck control axis", () => {
  test("App passes the person's handle, not the side the pill steps aside to", () => {
    const app = src("agent-session/acpmux/App.tsx");
    expect(app).toContain("tuckSide={trayHandle}");
    expect(app).not.toContain("tuckSide={hatHandle}");
  });

  test("its box is centred on the hat by default: left 50%, its own width, no side offset", () => {
    const css = src("agent-session/acpmux/subagents/subagents.css");
    const base = css.match(/\.acpmux-running-tray__tuck,[^{]*\{([^}]*)\}/)?.[1] ?? "";
    expect(base).toMatch(/left:\s*50%/);
    expect(base).toMatch(/translateX\(-50%\)/);
  });
});
