import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

// The bottom deck and Jump to latest share the bottom stack's top edge: the deck stands a gap above
// it, and the button 12px above it (conversation.css .acpmux-jump-latest), a layer under the deck. A
// router review of #37629: "a toast can cover it and take its clicks". While the button shows
// (.acpmux-main[data-jump-latest], from VirtualTranscript's onJumpShownChange), the deck stands above
// it. jsdom has no layout, so this checks the stylesheet's contract.
const css = readFileSync(join(import.meta.dir, "toastLayer.css"), "utf8");
const buttonCss = readFileSync(join(import.meta.dir, "conversation/conversation.css"), "utf8");
const pillCss = readFileSync(join(import.meta.dir, "needsYou/needsYou.css"), "utf8");
const tokenCss = readFileSync(join(import.meta.dir, "../../pages/shared/desktop.css"), "utf8");
// A height is a literal `Npx` or a design token (`var(--ds-…)`), read from desktop.css.
const px = (source: string, pattern: RegExp) => {
  const value = pattern.exec(source)?.[1] ?? "";
  const token = /^var\((--[\w-]+)\)$/.exec(value)?.[1];
  const resolved = token ? new RegExp(`${token}:\\s*(\\d+)px`).exec(tokenCss)?.[1] : value;
  return Number(resolved?.replace(/px$/, "") ?? Number.NaN);
};

describe("toast deck and Jump to latest", () => {
  const lifted =
    /\.acpmux-main\[data-jump-latest\]\s*>\s*\.acpmux-dock\s*>\s*\.acpmux-toasts\s*>\s*\.ui-notice-stack\s*\{([^}]*)\}/;

  test("while Jump to latest shows, the bottom deck is lifted past the whole button", () => {
    const rule = lifted.exec(css)?.[1];
    expect(rule).toBeDefined();
    expect(rule!).toMatch(/translate:\s*0\s+calc\(-1\s*\*\s*var\(--acpmux-toasts-jump-room\)\)/);
    // The room is the button's foot gap plus its tallest form (the Needs your input pill).
    const room = /--acpmux-toasts-jump-room:\s*calc\((\d+)px\s*\+\s*(\d+)px\)/.exec(css);
    expect(room).not.toBeNull();
    const foot = px(buttonCss, /\.acpmux-jump-latest\s*\{[^}]*bottom:\s*calc\((\d+)px/);
    const circle = px(buttonCss, /\.acpmux-jump-latest\s*\{[^}]*height:\s*(\d+px)/);
    const pill = px(pillCss, /\.acpmux-jump-latest\.acpmux-needs-you-pill\s*\{[^}]*height:\s*(\d+px|var\(--[\w-]+\))/);
    expect(Number.isFinite(pill)).toBe(true);
    expect(Number(room![1])).toBe(foot);
    expect(Number(room![2])).toBeGreaterThanOrEqual(Math.max(circle, pill));
  });

  test("the lift moves with the button's fade, and lands in one frame with motion off", () => {
    expect(css).toMatch(
      /:root:not\(\[data-cmux-motion="off"\],\s*\[data-cmux-motion="reduced"\],\s*\[data-agent-motion="off"\]\)\s*\.acpmux-toasts\s*>\s*\.ui-notice-stack\s*\{[^}]*transition:\s*translate\s+var\(--agent-motion-out\)/,
    );
    expect(css).toMatch(/@media \(prefers-reduced-motion: no-preference\)/);
  });
});
