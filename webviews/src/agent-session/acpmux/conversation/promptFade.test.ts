import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const css = readFileSync(join(import.meta.dir, "conversation.css"), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");

// A collapsed long prompt fades only its last line, as Claude and ChatGPT desktop do (Leo,
// 2026-11-01: "this is also blurring way too high i think"). Every line above it reads at full
// contrast, so the mask stays opaque until one line above the bottom.
test("a collapsed prompt's fade covers only its last line", () => {
  const rule = css.match(/\.cv-user__text\.is-faded\s*\{([^}]*)\}/);
  expect(rule).not.toBeNull();
  for (const prop of ["-webkit-mask-image", "mask-image"]) {
    const value = rule![1]!.match(new RegExp(`(?:^|[;\\s])${prop}:\\s*([^;]+);`))?.[1];
    expect(value).toBeDefined();
    // The opaque stop: `calc(100% - var(--cv-line-height)[ * N])`; N is the faded line count.
    const stop = value!.match(/calc\(100% - var\(--cv-line-height\)(?:\s*\*\s*([\d.]+))?\)/);
    expect(stop).not.toBeNull();
    expect(Number(stop![1] ?? 1)).toBeLessThanOrEqual(1);
  }
});
