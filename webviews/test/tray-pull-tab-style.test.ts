// The tucked hat's pull tab is a small glass control on the composer's hairline. It draws no line of
// its own beside the pill (Leo, 2026-11-11: "did this line behind the count box get removed yet?"):
// the card's line runs up to its rim (test/composer-hat-line-gap.test.ts measures the pixels). Keep
// its count type and glass tokens together when the tray is polished.
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";

const css = readFileSync(path.resolve(import.meta.dir, "../src/agent-session/acpmux/subagents/subagents.css"), "utf8");

function rule(selector: string): string {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return css.match(new RegExp(`${escaped}\\s*\\{([^}]*)\\}`))?.[1] ?? "";
}

// Its count is the real one, never capped at "99+" (Leo, 2026-11-22: "this can probably afford to
// show more than 99 numbers"): the number up to 999, then a compact one rounded down, at most four
// characters, and the pill's width in digits (a point is half one) for the line's gap.
describe("tucked hat pull tab count", () => {
  test("shows the real count, compact past 999, never more than runs", async () => {
    const { pullTabCountText } = await import("../src/agent-session/acpmux/subagents/trayPullTabModel");
    expect(pullTabCountText(1)).toBe("1");
    expect(pullTabCountText(99)).toBe("99");
    expect(pullTabCountText(100)).toBe("100");
    expect(pullTabCountText(128)).toBe("128");
    expect(pullTabCountText(999)).toBe("999");
    expect(pullTabCountText(1_000)).toBe("1k");
    expect(pullTabCountText(1_250)).toBe("1.2k");
    expect(pullTabCountText(1_299)).toBe("1.2k");
    expect(pullTabCountText(2_300)).toBe("2.3k");
    expect(pullTabCountText(9_999)).toBe("9.9k");
    expect(pullTabCountText(12_800)).toBe("12k");
    expect(pullTabCountText(128_000)).toBe("128k");
    expect(pullTabCountText(999_999)).toBe("999k");
    expect(pullTabCountText(1_250_000)).toBe("1.2M");
    for (const n of [0, 7, 99, 100, 999, 1_000, 1_234, 9_999, 10_000, 99_999, 100_000, 999_999, 1_000_000, 5e9])
      expect(pullTabCountText(n).length, String(n)).toBeLessThanOrEqual(4);
  });

  test("its width in digits, a point half one", async () => {
    const { pullTabCountWidth } = await import("../src/agent-session/acpmux/subagents/trayPullTabModel");
    expect(pullTabCountWidth("7")).toBe(1);
    expect(pullTabCountWidth("128")).toBe(3);
    expect(pullTabCountWidth("1.2k")).toBe(3.5);
    expect(pullTabCountWidth("128k")).toBe(4);
  });

  test("every width the count can take has its gap in the composer's line", () => {
    for (const mark of ["1", "2", "3", "3.5", "4"])
      expect(css, mark).toContain(`.acpmux-tray-pull[data-mark="${mark}"] + .acpmux-composer`);
  });
});

describe("tucked hat pull tab styling", () => {
  test("a compact glass control with no line of its own beside it", () => {
    const control = rule(".acpmux-tray-pull__hat");
    expect(css, "the pill draws no ::before or ::after stub").not.toMatch(/\.acpmux-tray-pull__hat::(before|after)/);
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
