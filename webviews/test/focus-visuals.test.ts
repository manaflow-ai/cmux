import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const acpmux = readFileSync(join(import.meta.dir, "../src/agent-session/acpmux/composerStates.css"), "utf8");
const location = readFileSync(join(import.meta.dir, "../src/agent-session/acpmux/composerLocation.css"), "utf8");
const desktop = readFileSync(join(import.meta.dir, "../src/pages/shared/desktop.css"), "utf8");
const transcript = readFileSync(
  join(import.meta.dir, "../src/agent-session/acpmux/conversation/conversation.css"),
  "utf8",
);

test("composer focus rims are modality-aware", () => {
  expect(acpmux).toContain(".acpmux-composer-box:has(:focus-visible)");
  expect(location).toContain(".acpmux-composer-box:has(:focus-visible)");
  expect(acpmux).not.toContain(".acpmux-composer-box:focus-within");
  expect(location).not.toContain(".acpmux-composer-box:focus-within");
});

test("transcript rows keep pointer focus quiet and keyboard focus visible", () => {
  expect(transcript).toContain(
    '[data-focus-ring-enabled="true"] .acpmux-row[data-transcript-active="true"]:focus-visible',
  );
  expect(transcript).toContain(".acpmux-row:focus:not(:focus-visible)");
  expect(desktop).toContain(".acpmux-row");
  expect(desktop).toContain('[role="searchbox"], .acpmux-row)):not');
});

test("Worked for keeps its keyboard-only outline contract", () => {
  expect(transcript).toContain(".cv-worked:focus-visible");
  expect(transcript).toContain(".cv-worked:focus:not(:focus-visible)");
  expect(transcript).toContain(".cv-tool.is-toggle:focus:not(:focus-visible)");
  expect(transcript).toContain(".cv-iconbtn:focus:not(:focus-visible)");
  expect(transcript).not.toMatch(/\.cv-worked:focus\s*\{/);
});
