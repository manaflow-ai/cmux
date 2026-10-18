import { expect, test } from "bun:test";
import { shouldWarmPath } from "./support/warmDevServer";

test("gallery warm-up skips unrelated lazy entry modules by default", () => {
  expect(
    shouldWarmPath("/gallery/src/agent-session/acpmux/Composer.gallery.tsx", "/gallery/src/gallery/registry.ts", false),
  ).toBe(false);
  expect(shouldWarmPath("/gallery/src/gallery/frame/main.ts", "/gallery/frame.html", false)).toBe(true);
  expect(shouldWarmPath("/gallery/src/agent-session/acpmux/Composer.gallery.tsx", "/gallery/frame.html?entry=agent-pane.composer", false)).toBe(false);
  expect(
    shouldWarmPath("/gallery/src/agent-session/acpmux/Composer.gallery.tsx", "/gallery/src/gallery/registry.ts", true),
  ).toBe(true);
});
