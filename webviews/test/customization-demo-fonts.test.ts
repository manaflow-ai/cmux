// A profile composes with the user's settings. A missing chat preset follows
// Markdown (or keeps a previous preset), so every demo must explicitly select sans.
import { expect, test } from "bun:test";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { chatDisplayVariables, chatMetrics, resolveChatDisplay } from "../src/agent-session/acpmux/chatDisplay";

const demo = new URL("../../examples/customize-demo/", import.meta.url);
const profiles = ["looks", "last-demo", "glass", "widgets"].flatMap((group) =>
  readdirSync(new URL(`${group}/`, demo))
    .filter((file) => file.endsWith(".json"))
    .map((file) => `${group}/${file}`),
);

test.each(profiles)("%s stays sans when applied over serif reading settings", (file) => {
  const profile = JSON.parse(readFileSync(fileURLToPath(new URL(file, demo)), "utf8"));
  const display = resolveChatDisplay({
    "markdown.font.preset": "serif",
    "agentPane.display.font.preset": "serif",
    "agentPane.display.code.family": "Menlo",
    ...profile.settings,
  });
  expect(display.font).toBe("system");
  expect(display.uiFamily).toBeNull();
  expect(display.proseFamily).toBeNull();
  expect(display.codeFamily).toBe("Menlo");
  expect(chatDisplayVariables(display)["--cv-reply-font"]).toBeNull();
  const metrics = chatMetrics(display);
  expect(metrics.replyMeasureFont).toBe(metrics.measureFont);
  expect(metrics.replyMeasureFont).not.toMatch(/Georgia|Iowan|ui-serif/);
});
