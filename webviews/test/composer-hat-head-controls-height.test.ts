// The controls laid over the composer hat's header take the header's own height (cmux#49587). The
// panel button and the `hide` button are absolutely placed at the header's top; a box of the lines'
// 28px row in a taller header (the `roomy` 34px default, trayHeadHeight.experiment.ts) put their
// icons above the chevron and the counts. The header, both buttons and each height arm go through
// one variable, `--acpmux-tray-head-height`. composer-hat-head-centre-line-browser.test.ts measures
// the drawn centres in Chromium.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";

const dir = path.resolve(import.meta.dir, "../src/agent-session/acpmux/subagents");
const css = readFileSync(path.join(dir, "subagents.css"), "utf8") + readFileSync(path.join(dir, "hatOpen.css"), "utf8");

/** The declarations of every rule whose selector list is exactly `selector`, in source order. */
function rule(selector: string): string {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const bodies = [...css.matchAll(new RegExp(`(?:^|\\n)${escaped}\\s*\\{([^}]*)\\}`, "g"))].map((m) => m[1]!);
  if (bodies.length === 0) throw new Error(`no rule for ${selector}`);
  return bodies.join(";");
}

/** The last `height` the rules declare (the one that wins). */
const height = (body: string) => [...body.matchAll(/(?:^|[;{\s])height:\s*([^;]+);/g)].at(-1)?.[1]?.trim();

test("the header and the buttons over it share one height", () => {
  expect(height(rule(".acpmux-running-tray__head"))).toBe("var(--acpmux-tray-head-height)");
  for (const button of [".acpmux-running-tray__open", ".acpmux-running-tray__hide"])
    expect(height(rule(button)), button).toStartWith("var(--acpmux-tray-head-height");
});

test("each header height arm sets the shared variable, not the header alone", () => {
  for (const arm of ["roomy", "tall"]) {
    const body = rule(`.acpmux-running-tray[data-head-height="${arm}"]`);
    expect(body, arm).toContain("--acpmux-tray-head-height:");
  }
  expect(css).not.toMatch(/\[data-head-height="[a-z]+"\]\s*>\s*\.acpmux-running-tray__head\s*\{[^}]*height:/);
});
