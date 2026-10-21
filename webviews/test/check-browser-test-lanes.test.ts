// The browser-lane checker's gallery-frame rule (scripts/check-browser-test-lanes.ts).
import { expect, test } from "bun:test";
import { checkGalleryFrameSource } from "../scripts/check-browser-test-lanes";

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
