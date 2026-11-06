// The tucked hat's pull tab is a small glass control joined to the composer's hairline. Keep its
// visible bridge, count alignment and glass tokens together when the tray is polished.
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
    const { pullTabCountText } = await import("../src/agent-session/acpmux/subagents/TrayPullTab");
    expect(pullTabCountText(1)).toBe("1");
    expect(pullTabCountText(99)).toBe("99");
    expect(pullTabCountText(100)).toBe("99+");
    expect(pullTabCountText(1250)).toBe("99+");
  });
});

describe("tucked hat pull tab styling", () => {
  test("the bridge meets a compact glass control", () => {
    const bridge = rule(".acpmux-tray-pull__tab::before");
    const control = rule(".acpmux-tray-pull__tab::after");
    expect(bridge).toContain("--cmux-hairline");
    expect(bridge).toContain("width: var(--ds-space-56)");
    expect(control).toContain("--glass-tint");
    expect(control).toContain("--glass-rim-shadow");
    expect(control).toContain("--ds-radius-control");
  });

  test("the count stays in the control and uses the compact type scale", () => {
    const count = [...css.matchAll(/\.acpmux-tray-pull__count\s*\{([^}]*)\}/g)].at(-1)?.[1] ?? "";
    expect(css).toContain("left: calc(50% + var(--ds-space-1))");
    expect(count).toContain("var(--text-caption)");
    expect(count).toContain("font-weight: 600");
    expect(count).toContain("var(--text-caption--letter-spacing)");
  });
});
