// The browser-lane checker's gallery-frame rule (scripts/check-browser-test-lanes.ts) and the
// gallery warm-up's reload test (support/galleryFrame.ts).
import { expect, test } from "bun:test";
import path from "node:path";
import { checkGalleryFrameSource, EVERY_ENTRY_PENDING } from "../scripts/check-browser-test-lanes";
import { reloaded } from "./support/galleryFrame";

const browserTest = (body: string) => `import { chromium } from "playwright";\n${body}\n`;

test("a browser test that opens a frame without entryPath is named, with its line", () => {
  const errors = checkGalleryFrameSource(
    "/x/test/a.test.ts",
    browserTest('await warmViteServer(vite, "/gallery/frame.html");'),
  );
  expect(errors).toHaveLength(1);
  expect(errors[0]).toContain(":2: opens a gallery frame without entryPath");
});

test("the helper, a frame narrowed to its entry, or an opt-out with a reason passes", () => {
  expect(
    checkGalleryFrameSource("a.test.ts", browserTest("await page.goto(base + galleryFrame(entry, { variant }));")),
  ).toEqual([]);
  expect(
    checkGalleryFrameSource(
      "a.test.ts",
      browserTest('await page.goto("/gallery/frame.html?entry=x&entryPath=src/x.gallery.ts");'),
    ),
  ).toEqual([]);
  expect(
    checkGalleryFrameSource(
      "a.test.ts",
      browserTest('// gallery-frame-every-entry: audits every entry\nawait page.goto("/gallery/frame.html");'),
    ),
  ).toEqual([]);
});

test("an opt-out needs a reason, and a test that opens no browser is not checked", () => {
  expect(
    checkGalleryFrameSource(
      "a.test.ts",
      browserTest('// gallery-frame-every-entry:\nawait page.goto("/gallery/frame.html");'),
    ),
  ).toHaveLength(1);
  expect(checkGalleryFrameSource("a.test.ts", 'expect(isGalleryFrame("/gallery/frame.html")).toBe(false);')).toEqual(
    [],
  );
});

// Any pending file; once the list is empty there is nothing to name.
const pending = [...EVERY_ENTRY_PENDING.keys()][0];

test.skipIf(!pending)("a pending test that opens no browser now is named, to leave the list", () => {
  const file = path.join(import.meta.dir, "..", pending!);
  expect(checkGalleryFrameSource(file, 'expect(isGalleryFrame("/gallery/frame.html")).toBe(false);')).toEqual([
    `${pending}: opens no browser now; remove it from EVERY_ENTRY_PENDING`,
  ]);
});

test("a warm-up retries an optimizer reload alone, whatever the URL spells", () => {
  const url = "http://127.0.0.1:5173/gallery/frame.html?entry=cancelled&entryPath=src/ERR_ABORTED.gallery.ts";
  expect(reloaded(new Error(`page.goto: net::ERR_ABORTED at ${url}\nCall log:\n  - navigating to "${url}"`))).toBe(
    true,
  );
  expect(
    reloaded(new Error("page.evaluate: Execution context was destroyed, most likely because of a navigation")),
  ).toBe(true);
  expect(
    reloaded(new Error(`page.goto: net::ERR_CONNECTION_REFUSED at ${url}\nCall log:\n  - navigating to "${url}"`)),
  ).toBe(false);
  expect(reloaded(new Error('page.goto: Timeout 1000ms exceeded.\nCall log:\n  - navigating to "x"'))).toBe(false);
});
