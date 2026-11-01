import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const css = readFileSync(join(import.meta.dir, "conversation.css"), "utf8");
const gallery = readFileSync(join(import.meta.dir, "transcript.gallery.ts"), "utf8");

test("background activity has one secondary tone and lifts on hover or focus; a step row only on focus", () => {
  expect(css).toContain("--cv-activity-text: color-mix(in srgb, var(--cv-fg) 58%, transparent);");
  // The lift skips a row whose session link chip has the focus: the chip lights alone (AgentTag.css).
  expect(css).toContain(".cv-tool:focus-within:not(:has(.cv-agent-tag.is-open:focus)),");
  // A step row draws nothing more on hover (agent-pane-step-rows.test.ts).
  expect(css).not.toMatch(/\.cv-tool:hover(,| \.cv-tool__(chevron|detail))/);
  expect(css).toContain(".cv-worked:hover,");
  expect(css).toMatch(/\.cv-received:is\(:hover, :active, :focus-within\)[^{]*\.cv-received__text\)/);
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
