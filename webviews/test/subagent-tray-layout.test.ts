import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const bottomStack = readFileSync(join(import.meta.dir, "../src/agent-session/acpmux/bottomStack.css"), "utf8");

test("the bottom-stack tray is flush with the composer and keeps the shared outer inset", () => {
  const rule = bottomStack.match(/\.acpmux-dock > \.acpmux-running-tray\s*\{([^}]*)\}/)?.[1] ?? "";
  // No bottom margin; the start and end insets match the composer's (the end one gives way to
  // --cv-inset-end where the pane sets it, #26068).
  expect(rule).toMatch(/margin:\s*0\s+var\(--cv-inset-end,\s*var\(--cv-inset\)\)\s+0\s+var\(--cv-inset\)\s*;/);
  expect(rule).not.toMatch(/8px/);
});
