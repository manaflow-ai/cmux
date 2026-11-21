// cmux-web-test-timeout: 400
// The Edit cloud environment sheet keeps its heading and its Cancel/Save row fixed, and the fields scroll in
// their own box between them, clipped above the actions (design/environment-sheet.md "Pages"). Review of
// cmux#38306 found a Header hint drawn under Cancel/Save and a secret's input under Save, with Add cut off
// at the sheet's edge: the fields overflowed their box instead of scrolling in it.
//
// Chromium on the gallery stage, `cloud.environment-sheet` in `secret-header-open` and
// `secret-many-expanded`, at two window heights: every header is opened by a real click, the fields are
// scrolled to their end, the last Header disclosure and Add must be what is under their own centers (not
// the footer), and every visible field, cut by the boxes that clip it, must stay inside the sheet and off
// the actions row.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("cloud-environment-sheet-geometry.test.ts", async () => {
  setDefaultTimeout(300_000);
  const ENTRY = "cloud.environment-sheet";
  const VARIANTS = ["secret-header-open", "secret-many-expanded"];
  /** Subpixel rounding. */
  const TOLERANCE = 0.5;
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch (error) {
    console.warn(
      `cloud-environment-sheet-geometry: skipping, chromium did not launch (${String(error).split("\n")[0]})`,
    );
    describe.skip("cloud environment sheet geometry", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    for (const variant of VARIANTS) await warmGalleryFrame(vite, ENTRY, { browser, params: { variant } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const settled = (page: Page) =>
    page.waitForFunction(() => document.getAnimations().every((animation) => animation.playState !== "running"));

  /** Scrolls `selector`'s last match into the fields' view and names what is under its center. */
  const hit = (page: Page, selector: string) =>
    page.evaluate((selector) => {
      const nodes = document.querySelectorAll<HTMLElement>(selector);
      const node = nodes[nodes.length - 1];
      if (!node) return { found: false, self: false, under: "" };
      node.scrollIntoView({ block: "nearest" });
      const rect = node.getBoundingClientRect();
      const under = document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
      const describe = (element: Element | null) =>
        element ? `${element.tagName.toLowerCase()}.${[...element.classList].join(".")}` : "nothing";
      return { found: true, self: under !== null && node.contains(under), under: describe(under) };
    }, selector);

  for (const variant of VARIANTS)
    for (const height of [640, 900])
      test(`${variant}, ${height} px tall: the fields scroll and clip above the actions; the last controls are reachable`, async () => {
        const page = await browser.newPage({ viewport: { width: 760, height } });
        try {
          const port = (vite!.httpServer!.address() as { port: number }).port;
          await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width: 700 })}`);
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
            timeout: 120_000,
          });
          await page.locator(".cloud-environment-sheet .env-secret").first().waitFor();
          // Every secret's header line is opened by a real click: Playwright's click
          // refuses an element another one covers, such as the actions row.
          const closed = page.locator('.env-secret > .env-disclosure[aria-expanded="false"]');
          while ((await closed.count()) > 0) await closed.first().click({ timeout: 10_000 });
          await settled(page);
          await page.evaluate(() => {
            const body = document.querySelector<HTMLElement>(".cloud-environment-sheet .env-scroll")!;
            body.scrollTop = body.scrollHeight;
          });

          const disclosure = await hit(page, ".env-secret > .env-disclosure");
          const add = await hit(page, ".cloud-environment-sheet .env-add");
          console.log(
            `${variant} ${height}px: last disclosure ${JSON.stringify(disclosure)}, add ${JSON.stringify(add)}`,
          );
          expect(disclosure).toMatchObject({ found: true, self: true });
          expect(add).toMatchObject({ found: true, self: true });

          const measured = await page.evaluate(() => {
            type Box = { top: number; bottom: number; left: number; right: number };
            const box = (element: Element): Box => {
              const { top, bottom, left, right } = element.getBoundingClientRect();
              return { top, bottom, left, right };
            };
            const meet = (a: Box, b: Box): Box | undefined => {
              const out = {
                top: Math.max(a.top, b.top),
                bottom: Math.min(a.bottom, b.bottom),
                left: Math.max(a.left, b.left),
                right: Math.min(a.right, b.right),
              };
              return out.bottom - out.top > 0.5 && out.right - out.left > 0.5 ? out : undefined;
            };
            const sheet = document.querySelector(".cloud-environment-sheet")!;
            const footer = box(sheet.querySelector(".env-actions")!);
            const body = sheet.querySelector<HTMLElement>(".env-scroll")!;
            /** What of `element` paints: its box cut by every ancestor up to the sheet that clips. */
            const painted = (element: Element): Box | undefined => {
              let shown: Box | undefined = box(element);
              for (let at = element.parentElement; at && shown; at = at.parentElement) {
                const style = getComputedStyle(at);
                if (style.overflowY !== "visible" || style.overflowX !== "visible") shown = meet(shown, box(at));
                if (at === sheet) break;
              }
              return shown;
            };
            const problems: string[] = [];
            const fields = body.querySelectorAll("input, textarea, button, small, .env-note, .env-secret-hosts > span");
            for (const field of fields) {
              if (field.closest("[inert]")) continue;
              const shown = painted(field);
              if (!shown) continue;
              const label = `${field.tagName.toLowerCase()}[${field.getAttribute("aria-label") ?? field.textContent?.slice(0, 24)}]`;
              if (meet(shown, footer)) problems.push(`${label} paints over the actions row`);
              const outside = meet(shown, box(sheet));
              if (!outside || Math.abs(outside.bottom - shown.bottom) > 0.5 || Math.abs(outside.top - shown.top) > 0.5)
                problems.push(`${label} paints outside the sheet`);
            }
            return {
              problems,
              footer,
              heading: box(sheet.querySelector(".env-heading")!),
              sheet: box(sheet),
              body: { ...box(body), overflowY: getComputedStyle(body).overflowY },
              scrolls: body.scrollHeight > body.clientHeight,
              viewport: window.innerHeight,
            };
          });
          console.log(`${variant} ${height}px: ${JSON.stringify(measured)}`);
          expect(measured.problems).toEqual([]);
          expect(measured.body.bottom).toBeLessThanOrEqual(measured.footer.top + TOLERANCE);
          // The heading and the actions stay in the sheet: nothing scrolls them away.
          expect(measured.heading.top).toBeGreaterThanOrEqual(measured.sheet.top - TOLERANCE);
          expect(measured.footer.top).toBeGreaterThanOrEqual(measured.heading.bottom - TOLERANCE);
          expect(measured.footer.bottom).toBeLessThanOrEqual(measured.sheet.bottom + TOLERANCE);
          expect(measured.sheet.bottom).toBeLessThanOrEqual(measured.viewport + TOLERANCE);

          // Add, clicked where it is, adds a row (it is not under the footer).
          const before = await page.locator(".cloud-environment-sheet .env-secret").count();
          await page.locator(".cloud-environment-sheet .env-add").click({ timeout: 10_000 });
          expect(await page.locator(".cloud-environment-sheet .env-secret").count()).toBe(before + 1);
        } finally {
          await page.close();
        }
      });
});
