import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const css = readFileSync(join(import.meta.dir, "conversation.css"), "utf8");
const gallery = readFileSync(join(import.meta.dir, "transcript.gallery.ts"), "utf8");

test("background activity has one secondary tone and lifts on hover", () => {
  expect(css).toContain("--cv-activity-text: color-mix(in srgb, var(--cv-fg) 58%, transparent);");
  expect(css).toContain(".cv-tool:hover,");
  expect(css).toContain(".cv-worked:hover,");
  expect(css).toContain(".cv-received:hover .cv-received__body,");
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
