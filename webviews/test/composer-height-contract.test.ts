import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const src = resolve(import.meta.dir, "../src/agent-session/acpmux");
const chat = readFileSync(resolve(src, "markdownField.css"), "utf8").replace(/\s+/g, "");
const newTab = readFileSync(resolve(src, "newtab/screen.css"), "utf8").replace(/\s+/g, "");
const chatGallery = readFileSync(resolve(src, "composerHeight.gallery.ts"), "utf8");
const newTabGallery = readFileSync(resolve(src, "newtab/ComposerHeight.gallery.ts"), "utf8");

test("all composer fields share the Goldilocks twelve-line, forty-percent cap", () => {
  expect(chat).toContain("*var(--acpmux-composer-max-lines,12)+var(--cmux-control-height,23px)");
  expect(chat).toContain("min(calc(");
  expect(newTab).toContain("var(--acpmux-composer-max-lines,12)*1lh+2*var(--nt-input-pad-block)");
  expect(newTab).toContain("min(calc(");
});

test("height comparison fixtures use the production typography and padding tokens", () => {
  expect(chatGallery).toContain("var(--text-content--line-height)");
  expect(chatGallery).not.toContain("var(--text-body--line-height");
  expect(newTabGallery).toContain('const PAD_BLOCK = "var(--nt-input-pad-block)"');
  expect(newTabGallery).toContain("2 * ${PAD_BLOCK}");
  expect(newTabGallery).not.toContain("+ 32px");
});
