import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const css = readFileSync(join(import.meta.dir, "conversation.css"), "utf8");
const agentRowCss = readFileSync(join(import.meta.dir, "AgentMessageRow.css"), "utf8");
const gallery = readFileSync(join(import.meta.dir, "transcript.gallery.ts"), "utf8");

test("selected message surfaces are borderless while the prompt keeps stronger glass", () => {
  expect(css).toContain("--glass-tint: color-mix(in srgb, var(--cv-fg) 10%, transparent);");
  expect(css).toContain("--glass-edge: transparent;");
  expect(css).toContain(".cv-received__body {");
  expect(css).toContain("background: transparent;");
  expect(css).toContain("box-shadow: none;");
  expect(agentRowCss).toContain(".cv-agentmsg__card {");
  expect(agentRowCss).toContain("background: none;");
  expect(agentRowCss).toContain("box-shadow: none;");
});

test("gallery keeps the bordered before arm and two borderless alternatives", () => {
  expect(gallery).toContain('"message-surfaces-bordered"');
  expect(gallery).toContain('"message-surfaces-soft"');
  expect(gallery).toContain('"message-surfaces-borderless"');
  expect(css).toContain(':root[data-message-surfaces="bordered"]');
  expect(css).toContain(':root[data-message-surfaces="soft"]');
});
