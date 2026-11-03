import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const css = readFileSync(join(import.meta.dir, "conversation.css"), "utf8");
const gallery = readFileSync(join(import.meta.dir, "transcript.gallery.ts"), "utf8");

test("background activity has one secondary tone and lifts on hover or focus; a step row only on focus; a received message never", () => {
  expect(css).toContain("--cv-activity-text: color-mix(in srgb, var(--cv-fg) 58%, transparent);");
  // The lift skips a row whose session link chip has the focus: the chip lights alone (AgentTag.css).
  // A tool run's or group's summary line (`is-run`) is left out: it lights on hover only. A sent
  // message's row keeps one steady tone, as a received one's does.
  expect(css).toContain(".cv-tool:not(.is-run, .cv-sent):focus-within:not(:has(.cv-agent-tag.is-open:focus)),");
  expect(css).not.toContain(".cv-tool:focus-within");
  expect(css).toMatch(/\.cv-tool\.is-run:hover > \.cv-tool__text \{\s*color: var\(--cv-text\);/);
  // A step row draws nothing more on hover (agent-pane-step-rows.test.ts).
  expect(css).not.toMatch(/\.cv-tool:hover(,| \.cv-tool__(chevron|detail))/);
  expect(css).toContain(".cv-worked:hover,");
  // A received message keeps one tone under the pointer and focus (Leo, 2026-11-03).
  expect(css).not.toMatch(/\.cv-received:is\(:hover/);
  expect(css).toContain(".cv-received__text :is(.cv-md, .cv-h),");
  expect(css).toContain(".cv-message:hover .cv-agentmsg__card,");
  expect(css).toContain("color: var(--cv-text);");
});

test("tone gallery includes readable alternatives on the same fixture", () => {
  expect(gallery).toContain('"activity-tone-secondary"');
  expect(gallery).toContain('"activity-tone-tertiary"');
  expect(gallery).toContain('"activity-tone-readable"');
  expect(gallery).toContain('"transcript-activity-tone": "tertiary"');
  expect(gallery).toContain('"transcript-activity-tone": "readable"');
});
