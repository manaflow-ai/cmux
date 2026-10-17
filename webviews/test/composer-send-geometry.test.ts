// The footer Send/Stop target is a 30 px rounded square. Keep its hit area aligned with the
// composer rail while preserving the 16 px arrow/square glyph and the reduced-motion state rules.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const css = readFileSync(join(import.meta.dir, "../src/agent-session/acpmux/composerLocation.css"), "utf8");

test("composer Send and Stop use the aligned rounded-square target", () => {
  const sendRule = [...css.matchAll(/\.acpmux-composer-bar \.acpmux-send\s*\{([^}]*)\}/g)]
    .map((match) => match[1] ?? "")
    .find((body) => body.includes("width: 30px")) ?? "";
  expect(sendRule).toContain("width: 30px");
  expect(sendRule).toContain("height: 30px");
  expect(sendRule).toContain("border-radius: var(--ui-row-radius, 8px)");
  expect(css).toContain(".acpmux-composer-bar .acpmux-send.acpmux-cancel");
});
