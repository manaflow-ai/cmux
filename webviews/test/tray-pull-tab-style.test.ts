// The tucked hat's pull tab is a small glass control joined to the composer's hairline. Keep its
// visible bridge (8px out from each side of the pill, so it follows the pill as it grows), count
// type and glass tokens together when the tray is polished.
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";

const css = readFileSync(path.resolve(import.meta.dir, "../src/agent-session/acpmux/subagents/subagents.css"), "utf8");

function rule(selector: string): string {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return css.match(new RegExp(`${escaped}\\s*\\{([^}]*)\\}`))?.[1] ?? "";
}

// Its count sits in a control sized for two digits: a hundred running lines read "99+", never a
// wider control (review of #36323 at 2c299524).
describe("tucked hat pull tab count", () => {
  test("shows up to 99, then 99+", async () => {
    const { pullTabCountText } = await import("../src/agent-session/acpmux/subagents/trayPullTabModel");
    expect(pullTabCountText(1)).toBe("1");
    expect(pullTabCountText(99)).toBe("99");
    expect(pullTabCountText(100)).toBe("99+");
    expect(pullTabCountText(1250)).toBe("99+");
  });
});

describe("tucked hat pull tab styling", () => {
  test("the bridge meets a compact glass control", () => {
    const bridge = rule(".acpmux-tray-pull__hat::before,\n.acpmux-tray-pull__hat::after");
    const control = rule(".acpmux-tray-pull__hat");
    expect(bridge).toContain("--cmux-hairline");
    expect(bridge).toContain("width: var(--ds-space-2)");
    expect(control).toContain("--glass-tint");
    expect(control).toContain("--glass-rim-shadow");
    expect(control).toContain("--ds-radius-control");
  });

  test("the count sits in the hat's slot and uses the compact type scale", () => {
    const slot = rule(".acpmux-tray-pull__slot");
    expect(slot).toContain("var(--text-caption)");
    expect(slot).toContain("font-weight: 600");
    expect(slot).toContain("tabular-nums");
    expect(slot).toContain("var(--text-caption--letter-spacing)");
  });
});
