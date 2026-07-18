import { describe, expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const shareStylesPath = join(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "app",
  "share",
  "[shareId]",
  "share-workspace.css",
);

describe("shared workspace visual chrome", () => {
  test("uses flat cmux chrome without gradients, glass, glow, or shadows", async () => {
    const css = await readFile(shareStylesPath, "utf8");

    expect(css).toContain("--cmux-window: #20211d");
    expect(css).toContain("--cmux-sidebar: #24251f");
    expect(css).toContain("--cmux-separator: #383933");
    expect(css).not.toMatch(/(?:linear|radial|conic)-gradient/u);
    expect(css).not.toContain("backdrop-filter");
    expect(css).not.toContain("box-shadow");
  });

  test("keeps a fixed workspace viewport with a compact mobile layout", async () => {
    const css = await readFile(shareStylesPath, "utf8");

    expect(css).toContain(".share-scene-canvas");
    expect(css).toContain("aspect-ratio: inherit");
    expect(css).toContain("@media (max-width: 760px)");
    expect(css).toContain(".share-chat");
  });
});
