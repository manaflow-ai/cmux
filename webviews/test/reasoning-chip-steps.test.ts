// The effort the model button names after the model (Leo 2026-10-20: one "Opus 5.5  Medium" button,
// no Reasoning chip), held before a session reports (#20946: the New Tab composer, a new chat) or
// reported, steps down as the row narrows (composerRowFit.ts effortShort): a narrow composer names
// the level's short form whole ("Med"), never a cut one ("M…" at 300 px, cg-ui-coord 2026-10-15). A
// wide one names it in full.
//
// These panes draw the button in the quiet row under the box, which takes no composer-width step
// (#24151, composerRowFit.ts paneWidth): it keeps the full name while the row's measured room holds
// it. At 400 px the model, its effort and "Bypass permissions" can fill these rows to within about
// 20 px of their room, so which form shows depends on the fonts (CI and huge-blue differ there).
// That width checks the form the row's fit chose (`data-fit-effort`), whole; 760 px (full) and
// 300 px (short) are well clear of the boundary.
//
// The held New Tab's quiet row holds only the mode and the model since #27956 moved its folder and
// computer above the box (Leo 2026-10-29: "project and cloudness at the top"), so at 300 px it has
// room near the boundary for "Medium" (CI reads "Medium" there): that width checks the fit's form,
// and 240 px is the narrow one that must read "Med".
//
// The gallery's real panes in Chromium: `agent-pane.new-tab` (`reasoning-chip`) and
// `agent-pane.composer` (`new-chat-reasoning`), and a New Tab whose agent reported its levels
// (`agent-pane.narrow` `new-tab`, "Medium Fast"), at 760, 400 and 300 px.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("reasoning-chip-steps.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("reasoning-chip-steps: skipping (run `bunx playwright install chromium`)");
    describe.skip("reasoning chip steps", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (entry: string, variant: string, width: number) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(entry, { variant, frame: "component", width })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.composer", { browser, params: { variant: "new-chat-reasoning" } });
    await warmGalleryFrame(vite, ["agent-pane.new-tab", "agent-pane.narrow"], { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (entry: string, variant: string, width: number): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width: width + 40, height: 640 } });
    await page.goto(url(entry, variant, width));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.locator(".acpmux-chips .acpmux-model .acpmux-model-detail").first().waitFor({ state: "attached" });
    await page.evaluate(() => document.fonts.ready);
    // The row lays out again with the loaded fonts: two painted frames later it has.
    await installPaintedFrames(page);
    await page.evaluate(() => window.cmuxPaintFrame().then(() => window.cmuxPaintFrame()));
    return page;
  };

  /** Runs in the page: the model button's drawn effort labels (text and ::before) and any it cuts. */
  function effortChip() {
    const button = document.querySelector<HTMLElement>(".acpmux-chips .acpmux-model .acpmux-picker-button")!;
    const shown = (element: Element) =>
      element.getClientRects().length > 0 && getComputedStyle(element).visibility === "visible";
    const box = button.getBoundingClientRect();
    const labels: string[] = [];
    const cut: string[] = [];
    const parts: Element[] = [];
    const details = [...button.querySelectorAll(".acpmux-model-detail")];
    for (const element of details)
      if (element.textContent?.trim() && shown(element)) {
        labels.push(element.textContent.trim());
        parts.push(element);
      }
    for (const element of details) {
      const content = getComputedStyle(element, "::before").content;
      if (/^".+"$/.test(content) && shown(element)) {
        labels.push(content.slice(1, -1).trim());
        parts.push(element);
      }
    }
    // The visible parts only: the button lays its other forms out of the row, hidden, so they still
    // measure (composerRowFit.ts), and its own scroll width counts them.
    for (const element of parts) {
      const style = getComputedStyle(element);
      const value = element.textContent?.trim() || style.content;
      if (element.scrollWidth > element.clientWidth + 0.5 && style.display !== "inline")
        cut.push(`"${value}" overflows its box by ${element.scrollWidth - element.clientWidth} px`);
      if (style.textOverflow === "ellipsis" && element.scrollWidth > element.clientWidth + 0.5)
        cut.push(`"${value}" ends in an ellipsis`);
      const rect = element.getBoundingClientRect();
      if (rect.left < box.left - 0.5 || rect.right > box.right + 0.5) cut.push(`"${value}" runs outside its button`);
    }
    return { labels, cut };
  }

  /** Each width's label; [full, short] where the row's own fit picks (above). */
  const held: Record<number, string | [string, string]> = { 760: "Medium", 400: ["Medium", "Med"], 300: "Med" };
  // New Tab's quiet row without the folder and computer (#27956): 240 px is its narrow width.
  const heldNewTab: Record<number, string | [string, string]> = {
    760: "Medium",
    400: ["Medium", "Med"],
    300: ["Medium", "Med"],
    240: "Med",
  };
  // Its level is one option named "Medium Fast": the short form is its first word's.
  const reported: Record<number, string | [string, string]> = {
    760: "Medium Fast",
    400: ["Medium Fast", "Med"],
    300: "Med",
  };
  const title = (label: string | [string, string]) =>
    typeof label === "string" ? `"${label}"` : `"${label[0]}" or "${label[1]}", as the row fits`;
  const cases: [string, string, string, Record<number, string | [string, string]>][] = [
    ["New Tab", "agent-pane.new-tab", "reasoning-chip", heldNewTab],
    ["new chat", "agent-pane.composer", "new-chat-reasoning", held],
    ["New Tab, reported", "agent-pane.narrow", "new-tab", reported],
  ];
  for (const [where, entry, variant, expected] of cases)
    for (const width of Object.keys(expected)
      .map(Number)
      .sort((a, b) => b - a))
      test(`${where} at ${width} px: the model button's effort reads ${title(expected[width]!)} whole`, async () => {
        const page = await open(entry, variant, width);
        const chip = await page.evaluate(effortChip);
        expect(chip.cut, "no label cut").toEqual([]);
        const label = expected[width]!;
        if (typeof label === "string") expect(chip.labels, "the level's whole name").toEqual([label]);
        else {
          // The short form only where the row's fit took the effort's step, the full one otherwise.
          const short = await page.evaluate(
            () =>
              document.querySelector(".acpmux-chips")?.closest<HTMLElement>(".acpmux-composer-bar")?.dataset
                .fitEffort === "short",
          );
          expect(chip.labels, "the form the row's fit chose, whole").toEqual([short ? label[1] : label[0]]);
        }
        // One model control: no separate Reasoning chip beside it.
        expect(await page.locator(".acpmux-chips .acpmux-effort").count()).toBe(0);
        await page.close();
      });
});
