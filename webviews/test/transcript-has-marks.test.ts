// The transcript's rules that styled every icon, every prompt's bubble and every prompt's action row
// past a `:has()` ask marks their owners set instead (test/transcript-insert-restyle.test.ts measures
// why): Chromium restyled each of those elements in the pane whenever the rail under the transcript
// gained an entry, each row an older page added. A popup opened inside the composer's tray tab marks
// the tab `data-popup-within` (ui/popupWithin.ts); a waiting steer's controls mark their prompt
// `data-steer-pending` (PendingSteer.tsx); a prompt's body says it holds the pending footer with
// `data-actions-pending` (UserBubble.tsx). Plain bun lane, no browser.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const ACPMUX = join(import.meta.dir, "../src/agent-session/acpmux");
const SHEETS = ["conversation/conversation.css", "subagents/subagents.css"];

/// The selectors converted to marks, each as it was written.
const FORBIDDEN = [
  ".acpmux-tray-pull__tab:has([data-popup-open])",
  ".cv-user:has(.cv-user__actions--pending) .cv-user__bubble",
  ".cv-user:is(:not(:has(.cv-user__pending)), :has(.cv-user__bubble))",
  ".cv-user__body:has(> .cv-user__actions--pending)",
  ".cv-user__body:has(> .cv-user__bubble) >",
  ".cv-user__body:has(> .cv-user__bubble):has(> .cv-user__actions--pending)",
];

test("the transcript's converted `:has()` selectors stay gone", () => {
  const found = SHEETS.flatMap((sheet) => {
    const text = readFileSync(join(ACPMUX, sheet), "utf8");
    return FORBIDDEN.filter((selector) => text.includes(selector)).map((selector) => `${sheet}: ${selector}`);
  });
  expect(found).toEqual([]);
});

test("the marks they ask are the ones their owners set", () => {
  const css = SHEETS.map((sheet) => readFileSync(join(ACPMUX, sheet), "utf8")).join("\n");
  const source = (file: string) => readFileSync(join(ACPMUX, file), "utf8");
  expect(css).toContain(".acpmux-tray-pull__tab[data-popup-within]");
  expect(css).toContain(".cv-user:not([data-steer-pending])");
  expect(source("conversation/PendingSteer.tsx")).toContain('setAttribute("data-steer-pending"');
  expect(css).toContain(".cv-user__body[data-actions-pending]");
  expect(source("conversation/UserBubble.tsx")).toContain("data-actions-pending=");
});
