// https://github.com/manaflow-ai/cmux/issues/59858: a message's only image in Home/Chief chat keeps
// its own shape: a width and an aspect ratio with height auto, so a narrow chat scales it down whole
// instead of keeping its height (cropping or stretching it).
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { singleImageStyle } from "../src/pages/home-channels/AttachmentViews";

test("a single image's frame is a width and its aspect ratio, height auto", () => {
  const tall = singleImageStyle({ width: 1352, height: 2358 });
  expect(tall.height).toBe("auto");
  const [w, h] = tall.aspectRatio.split("/").map((value) => Number(value.trim()));
  expect(tall.width).toBe(w!);
  expect(h).toBe(280);
  expect(Math.abs(w! / h! - 1352 / 2358)).toBeLessThan(0.01);
  const wide = singleImageStyle({ width: 2880, height: 900 });
  expect(wide.width).toBe(360);
  // Never larger than the image.
  expect(singleImageStyle({ width: 100, height: 50 }).width).toBe(100);
});

test("a single image letterboxes in its frame, never crops", () => {
  const css = readFileSync(new URL("../src/pages/home-channels/ledger.css", import.meta.url), "utf8");
  expect(css).toMatch(/\.hc-att-image\.single img\s*\{[^}]*object-fit:\s*contain/);
});
