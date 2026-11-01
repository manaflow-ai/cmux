import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const bottomStack = readFileSync(join(import.meta.dir, "../src/agent-session/acpmux/bottomStack.css"), "utf8");

test("the bottom-stack tray is flush with the composer and keeps the shared outer inset", () => {
  const rule = bottomStack.match(/\.acpmux-dock > \.acpmux-running-tray\s*\{([^}]*)\}/)?.[1] ?? "";
  // No bottom margin; the start and end insets match the composer's (the end one gives way to
  // --cv-inset-end where the pane sets it, #26068).
  expect(rule).toMatch(/margin:\s*0\s+calc\(var\(--cv-inset-end,/);
  expect(rule).toContain("--acpmux-tray-outset");
  expect(rule).not.toMatch(/margin:[^;]*8px/);
});

// Leo, 2026-10-29: "why the fuck do you still have this fucking thing at the bottom of the running
// thing? ... It's just unnecessary, stupid-ass fucking padding." The stack's 34px row floor left a
// strip of tray glass under the tray's 28px header; the tray's floor is its one row.
test("the bottom-stack tray's floor is its one row, not the stack's taller row", () => {
  const rules = [
    ...bottomStack
      .replace(/@media[^{]*\{(?:[^{}]*\{[^}]*\})*[^}]*\}/g, "")
      .matchAll(/\.acpmux-dock > \.acpmux-running-tray\s*\{([^}]*)\}/g),
  ].map((match) => match[1]!);
  const floors = rules.flatMap((rule) =>
    [...rule.matchAll(/min-height:\s*([^;]+);/g)].map((match) => match[1]!.trim()),
  );
  expect(floors.at(-1)).toBe("var(--ui-row-height, var(--ds-control-row, 28px))");
  // The header is one row at every width (its time follows its counts), so a narrow tray keeps the
  // same one-row floor: no strip of glass under a folded header.
  expect(bottomStack).not.toMatch(/\.acpmux-dock\s*>\s*\.acpmux-running-tray\[data-narrow\]/);
});
