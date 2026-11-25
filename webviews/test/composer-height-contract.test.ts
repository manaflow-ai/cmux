import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const src = resolve(import.meta.dir, "../src/agent-session/acpmux");
const chat = readFileSync(resolve(src, "markdownField.css"), "utf8").replace(/\s+/g, "");
const newTab = readFileSync(resolve(src, "newtab/screen.css"), "utf8").replace(/\s+/g, "");
const chatGallery = readFileSync(resolve(src, "composerHeight.gallery.ts"), "utf8");
const newTabGallery = readFileSync(resolve(src, "newtab/ComposerHeight.gallery.ts"), "utf8");

// Leo 2026-11-24: follow Claude desktop's composer max (its prompt stops at 384 px, max-h-96).
const CAP = "var(--acpmux-composer-max-height,calc(384px*var(--cmux-interface-scale,1)))";
test("all composer fields share Claude desktop's 384 px cap", () => {
  const styles = readFileSync(resolve(src, "styles.css"), "utf8").replace(/\s+/g, "");
  expect(styles).toContain(".acpmux-shell{--acpmux-composer-max-height:calc(384px*var(--cmux-interface-scale,1))}");
  expect(chat).toContain(`max-height:min(${CAP},50vh)`);
  expect(newTab).toContain(`max-height:min(${CAP},50vh)`);
  expect(styles).toContain(`max-height:min(${CAP},50vh)`);
  for (const css of [chat, newTab, styles]) {
    expect(css).not.toContain("composer-max-lines");
    expect(css).not.toContain("60vh);margin");
  }
});

test("height comparison fixtures use the production typography and padding tokens", () => {
  expect(chatGallery).toContain("var(--text-content--line-height)");
  expect(chatGallery).not.toContain("var(--text-body--line-height");
  expect(newTabGallery).toContain('const PAD_BLOCK = "var(--nt-input-pad-block)"');
  expect(newTabGallery).toContain("2 * ${PAD_BLOCK}");
  expect(newTabGallery).not.toContain("+ 32px");
});
