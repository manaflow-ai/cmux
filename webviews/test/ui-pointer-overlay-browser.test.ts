// l10n-allow-file: fixture element text, not shipped UI.
// The UI inspector says what it is for and shows what you would pick before you click (Leo,
// 2026-11-08: "im also not entirely sure what it's used for" and "you should be able to just see
// maybe some sort of preview as you're going and hovering, and ... on your initial inspect element
// escapade as well"). While picking, a hint names the tool and its keys; a label beside the outline
// shows the element's name, text and size, stays on screen and never covers the element; Esc
// cancels from the page; arrow keys walk the tree and Enter picks, none of them reaching the page.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("ui-pointer-overlay-browser.test.ts", async () => {
  setDefaultTimeout(60_000);
  const dir = fs.mkdtempSync(path.join(import.meta.dir, ".ui-pointer-overlay-"));
  const strings = path.join(dir, "strings.ts");
  const entry = path.join(dir, "entry.ts");
  fs.writeFileSync(
    strings,
    `
    import table from "../../src/agent-session/acpmux/generated/strings.json";
    (globalThis as any).__cmuxPaneStrings = table;
  `,
  );
  fs.writeFileSync(
    entry,
    `
    import "./strings";
    import { installUiPointer } from "../../src/agent-session/acpmux/uiPointer/picker";
    const state = (window as any).state = { now: 0, cancels: 0, reports: [] as { text_content: string }[] };
    (window as any).picker = installUiPointer(document, {
      post: (r) => state.reports.push(r),
      cancel: () => state.cancels++,
      now: () => state.now,
    });
  `,
  );
  const built = await Bun.build({ entrypoints: [entry], target: "browser" }).finally(() =>
    fs.rmSync(dir, { recursive: true, force: true }),
  );
  if (!built.success) throw new Error(built.logs.join("\n"));
  const script = await built.outputs[0].text();
  const css = fs.readFileSync(
    path.join(import.meta.dir, "../src/agent-session/acpmux/uiPointer/uiPointer.css"),
    "utf8",
  );

  let browser: Browser;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  const VIEW = { width: 480, height: 560 };

  async function open(): Promise<Page> {
    const page = await browser.newPage({ viewport: VIEW, reducedMotion: "reduce" });
    await page.setContent(`<style>
      body{margin:0;font:13px sans-serif} .abs{position:absolute;margin:0;box-sizing:border-box}
    </style>
    <p class="abs" id="tl" style="left:0;top:0;width:120px;height:30px">Top left</p>
    <p class="abs" id="banner" style="left:140px;top:0;width:200px;height:30px">Banner</p>
    <p class="abs" id="tr" style="right:0;top:0;width:100px;height:30px">Top right</p>
    <p class="abs" id="mid" style="left:120px;top:200px;width:200px;height:40px">Middle row</p>
    <section class="abs" id="tree" data-cmux-component="Thread" style="left:20px;top:300px;width:300px;height:100px">
      <div id="row1"><span id="s1">One</span> <span id="s2">Two</span></div>
      <div id="row2">Second row</div>
    </section>
    <section class="abs" id="wrapped" style="left:340px;top:300px;width:120px;height:100px">
      <div id="contents" style="display:contents"><span id="inner">Inner</span></div>
    </section>
    <input class="abs" id="field" style="left:20px;top:440px;width:200px;height:24px">
    <p class="abs" id="bl" style="left:0;bottom:0;width:120px;height:30px">Bottom left</p>
    <p class="abs" id="br" style="right:0;bottom:0;width:100px;height:30px">Bottom right</p>
    <script>
      window.keys = [];
      document.getElementById("field").addEventListener("keydown", (e) => window.keys.push(e.key));
      document.addEventListener("contextmenu", (e) => e.preventDefault());
    </script>`);
    await page.addStyleTag({ content: css });
    await page.addScriptTag({ content: script });
    return page;
  }

  const outlined = (page: Page) =>
    page.evaluate(() => ((window as any).picker.current() as Element | null)?.id ?? null);
  const at = (page: Page, now: number) => page.evaluate((t) => ((window as any).state.now = t), now);
  const hover = async (page: Page, id: string) => {
    const box = await page.locator(`#${id}`).boundingBox();
    if (!box) throw new Error(`no box for ${id}`);
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  };
  type Rect = { x: number; y: number; width: number; height: number };
  const rect = (page: Page, selector: string) =>
    page.evaluate((s) => {
      const r = document.querySelector(s)?.getBoundingClientRect();
      return r ? { x: r.x, y: r.y, width: r.width, height: r.height } : null;
    }, selector);
  const text = (page: Page, selector: string) =>
    page.evaluate((s) => (document.querySelector(s) as HTMLElement | null)?.innerText ?? null, selector);
  const edge = (page: Page) =>
    page.evaluate((s) => document.querySelector(s)?.getAttribute("data-edge") ?? null, "[data-cmux-ui-pointer-hint]");
  const LABEL = "[data-cmux-ui-pointer-label]";
  const HINT = "[data-cmux-ui-pointer-hint]";
  const overlaps = (a: Rect, b: Rect) =>
    a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height;

  test("start shows the hint that says what the picker is for; stop removes it", async () => {
    const page = await open();
    await page.evaluate(() => (window as any).picker.start());
    const hint = await text(page, HINT);
    expect(hint).toContain("Pick a UI element to point your agent at it");
    expect(hint).toContain("esc");
    await page.evaluate(() => (window as any).picker.stop());
    expect(await page.locator("[data-cmux-ui-pointer]").count()).toBe(0);
    await page.close();
  });

  test("the hint moves to the bottom edge when the outline is under it", async () => {
    const page = await open();
    await page.evaluate(() => (window as any).picker.start());
    await hover(page, "mid");
    expect(await edge(page)).toBe("top");
    await hover(page, "banner");
    expect(await edge(page)).toBe("bottom");
    const hint = (await rect(page, HINT))!;
    expect(overlaps(hint, (await rect(page, "#banner"))!)).toBe(false);
    await page.close();
  });

  test("hovering shows the label with name, text and size beside the element", async () => {
    const page = await open();
    await page.evaluate(() => (window as any).picker.start());
    await hover(page, "mid");
    expect(await outlined(page)).toBe("mid");
    expect(await text(page, `${LABEL} [data-part="name"]`)).toBe("p");
    expect(await text(page, `${LABEL} [data-part="selector"]`)).toBe("p#mid");
    expect(await text(page, `${LABEL} [data-part="snippet"]`)).toContain("Middle row");
    expect(await text(page, `${LABEL} [data-part="size"]`)).toBe("200×40");
    expect(await text(page, `${LABEL} [data-part="styles"]`)).toContain("13px");
    await hover(page, "s1");
    expect(await text(page, `${LABEL} [data-part="name"]`)).toBe("Thread");
    await page.close();
  });

  for (const id of ["tl", "tr", "bl", "br", "mid", "banner"])
    test(`the label at #${id} stays inside the viewport and off the element`, async () => {
      const page = await open();
      await page.evaluate(() => (window as any).picker.start());
      await hover(page, id);
      const label = (await rect(page, LABEL))!;
      const element = (await rect(page, `#${id}`))!;
      expect(label.width).toBeGreaterThan(0);
      expect(label.x).toBeGreaterThanOrEqual(0);
      expect(label.y).toBeGreaterThanOrEqual(0);
      expect(label.x + label.width).toBeLessThanOrEqual(VIEW.width);
      expect(label.y + label.height).toBeLessThanOrEqual(VIEW.height);
      expect(overlaps(label, element)).toBe(false);
      await page.close();
    });

  test("Esc cancels: the overlay goes and the key never reaches the focused input", async () => {
    const page = await open();
    await page.focus("#field");
    await page.evaluate(() => (window as any).picker.start());
    await hover(page, "mid");
    await page.keyboard.press("Escape");
    expect(await page.locator("[data-cmux-ui-pointer]").count()).toBe(0);
    expect(await page.evaluate(() => (window as any).keys)).toEqual([]);
    expect(await page.evaluate(() => (window as any).state.cancels)).toBe(1);
    // After the cancel the page has its keys back.
    await page.keyboard.press("a");
    expect(await page.evaluate(() => (window as any).keys)).toEqual(["a"]);
    await page.close();
  });

  test("arrow keys walk the tree; the outline and label follow; the input never sees them", async () => {
    const page = await open();
    await page.focus("#field");
    await page.evaluate(() => (window as any).picker.start());
    await hover(page, "s1");
    expect(await outlined(page)).toBe("s1");
    await page.keyboard.press("ArrowRight");
    expect(await outlined(page)).toBe("s2");
    await page.keyboard.press("ArrowLeft");
    expect(await outlined(page)).toBe("s1");
    await page.keyboard.press("ArrowUp");
    expect(await outlined(page)).toBe("row1");
    expect(await text(page, `${LABEL} [data-part="selector"]`)).toBe("div#row1");
    await page.keyboard.press("ArrowUp");
    expect(await outlined(page)).toBe("tree");
    await page.keyboard.press("ArrowDown");
    expect(await outlined(page)).toBe("row1");
    await page.keyboard.press("ArrowDown");
    expect(await outlined(page)).toBe("s1");
    await page.keyboard.press("ArrowDown"); // a leaf: stays
    expect(await outlined(page)).toBe("s1");
    await page.keyboard.press("ArrowUp");
    await page.keyboard.press("ArrowRight");
    expect(await outlined(page)).toBe("row2");
    // The outline is on the walked element.
    const outline = (await rect(page, "[data-cmux-ui-pointer-outline]"))!;
    const row2 = (await rect(page, "#row2"))!;
    expect(Math.round(outline.y)).toBe(Math.round(row2.y));
    expect(Math.round(outline.height)).toBe(Math.round(row2.height));
    expect(await page.evaluate(() => (window as any).keys)).toEqual([]);
    expect(await page.inputValue("#field")).toBe("");
    await page.close();
  });

  test("the walk steps through a wrapper that draws no box (display: contents), both ways", async () => {
    const page = await open();
    await page.evaluate(() => (window as any).picker.start());
    await hover(page, "inner");
    expect(await outlined(page)).toBe("inner");
    // Up skips the wrapper: it has no box to outline or report.
    await page.keyboard.press("ArrowUp");
    expect(await outlined(page)).toBe("wrapped");
    const outline = (await rect(page, "[data-cmux-ui-pointer-outline]"))!;
    expect(Math.round(outline.width)).toBe(120);
    await page.keyboard.press("ArrowDown");
    expect(await outlined(page)).toBe("inner");
    await page.close();
    // From a hover on the outer element, with no trail, Down still finds the child inside the wrapper.
    const fresh = await open();
    await fresh.evaluate(() => (window as any).picker.start());
    await hover(fresh, "wrapped");
    expect(await outlined(fresh)).toBe("wrapped");
    await fresh.keyboard.press("ArrowDown");
    expect(await outlined(fresh)).toBe("inner");
    await fresh.close();
  });

  test("after a walk a small move keeps the walked element; a deliberate one resumes hovering", async () => {
    const page = await open();
    await page.evaluate(() => (window as any).picker.start());
    await hover(page, "s1");
    await at(page, 100);
    await page.keyboard.press("ArrowUp");
    expect(await outlined(page)).toBe("row1");
    const s1 = (await page.locator("#s1").boundingBox())!;
    await page.mouse.move(s1.x + s1.width / 2 + 2, s1.y + s1.height / 2);
    await at(page, 900);
    await page.mouse.move(s1.x + s1.width / 2 + 4, s1.y + s1.height / 2);
    expect(await outlined(page)).toBe("row1");
    await hover(page, "mid");
    expect(await outlined(page)).toBe("mid");
    await page.close();
  });

  test("Enter picks the outlined element, the walked one included, and the input never sees it", async () => {
    const page = await open();
    await page.focus("#field");
    await page.evaluate(() => (window as any).picker.start());
    await hover(page, "s1");
    await page.keyboard.press("ArrowUp");
    await page.keyboard.press("Enter");
    const reports = await page.evaluate(() =>
      (window as any).state.reports.map((r: any) => [r.selector, r.text_content]),
    );
    expect(reports).toEqual([["#row1", "One Two"]]);
    expect(await page.evaluate(() => (window as any).keys)).toEqual([]);
    await page.close();
  });

  test("the held element after Inspect Element shows its label at once", async () => {
    const page = await open();
    await page.mouse.move(60, 215);
    await page.mouse.click(160, 215, { button: "right" });
    await page.mouse.move(60, 520, { steps: 3 });
    await page.evaluate(() => (window as any).picker.inspectMenuTarget(160, 215));
    expect(await outlined(page)).toBe("mid");
    expect(await text(page, `${LABEL} [data-part="snippet"]`)).toContain("Middle row");
    expect(await text(page, HINT)).toContain("Pick a UI element");
    await page.close();
  });

  test("no keys are taken while the picker is off", async () => {
    const page = await open();
    await page.focus("#field");
    await page.keyboard.press("ArrowUp");
    await page.keyboard.press("Escape");
    expect(await page.evaluate(() => (window as any).keys)).toEqual(["ArrowUp", "Escape"]);
    await page.close();
  });
});
