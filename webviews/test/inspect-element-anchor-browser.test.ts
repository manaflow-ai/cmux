// l10n-allow-file: fixture element text, not shipped UI.
// Right-click > Inspect Element picks the element that was right-clicked, not the one under the
// menu row the pointer chose (Leo, 2026-11-08: "instead of ... it being at your original cursor's
// position where you started the right-click menu, it does it at where your mouse currently is").
// The page drives the picker the way the native controller does (UIInspectorController): a real
// right-click on A, the pointer down over B (where the menu row was), then `inspectMenuTarget` at
// the right-click point. A holds through the grace (grace.ts) and a click picks it; a deliberate
// move after the grace resumes hover-picking. The grace clock is the page's own fake clock.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("inspect-element-anchor-browser.test.ts", async () => {
  setDefaultTimeout(60_000);
  const dir = fs.mkdtempSync(path.join(import.meta.dir, ".inspect-element-anchor-"));
  const entry = path.join(dir, "entry.ts");
  fs.writeFileSync(
    entry,
    `
    import { installUiPointer } from "../../src/agent-session/acpmux/uiPointer/picker";
    const state = (window as any).state = { now: 0, reports: [] as { text_content: string }[] };
    (window as any).picker = installUiPointer(document, { post: (r) => state.reports.push(r), now: () => state.now });
  `,
  );
  const built = await Bun.build({ entrypoints: [entry], target: "browser" }).finally(() =>
    fs.rmSync(dir, { recursive: true, force: true }),
  );
  if (!built.success) throw new Error(built.logs.join("\n"));
  const script = await built.outputs[0].text();

  let browser: Browser;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  const A = { x: 60, y: 40 };
  const B = { x: 60, y: 240 };
  const C = { x: 60, y: 440 };

  async function open(): Promise<Page> {
    const page = await browser.newPage({ viewport: { width: 480, height: 560 } });
    await page.setContent(`<style>
      body{margin:0} p{position:absolute;left:20px;width:300px;height:40px;margin:0}
    </style><p id="a" style="top:20px">A, right-clicked</p><p id="b" style="top:220px">B, under the menu row</p>
    <p id="c" style="top:420px">C, moved to on purpose</p>
    <script>document.addEventListener("contextmenu", (e) => e.preventDefault());</script>`);
    await page.addScriptTag({ content: script });
    return page;
  }

  const outlined = (page: Page) =>
    page.evaluate(() => ((window as any).picker.current() as Element | null)?.id ?? null);
  const at = (page: Page, now: number) => page.evaluate((t) => ((window as any).state.now = t), now);

  async function inspectFromMenu(page: Page) {
    await page.mouse.move(A.x, A.y);
    await page.mouse.click(A.x, A.y, { button: "right" });
    // The person moves down the menu to its Inspect Element row, over B, and chooses it.
    await page.mouse.move(B.x, B.y, { steps: 4 });
    await page.evaluate(([x, y]) => (window as any).picker.inspectMenuTarget(x, y), [A.x, A.y]);
  }

  test("right-click A, choose Inspect over B: A is outlined and a click picks A", async () => {
    const page = await open();
    await inspectFromMenu(page);
    expect(await outlined(page)).toBe("a");
    await at(page, 50);
    await page.mouse.move(B.x + 3, B.y + 2); // the pointer leaving the menu row
    expect(await outlined(page)).toBe("a");
    await page.evaluate(([x, y]) => (window as any).picker.pick(x, y), [B.x + 3, B.y + 2]);
    const reports = await page.evaluate(() => (window as any).state.reports.map((r: any) => r.text_content));
    expect(reports).toEqual(["A, right-clicked"]);
    await page.close();
  });

  test("the hold survives a big move inside the grace time and a small move after it", async () => {
    const page = await open();
    await inspectFromMenu(page);
    await at(page, 20);
    await page.mouse.move(B.x, B.y + 1); // origin: the first move after the menu
    await at(page, 300);
    await page.mouse.move(C.x, C.y, { steps: 3 }); // far, but inside 500 ms
    expect(await outlined(page)).toBe("a");
    await page.mouse.move(B.x, B.y + 1, { steps: 3 });
    await at(page, 900);
    await page.mouse.move(B.x + 10, B.y + 1); // after the grace, under 16 px from the origin
    expect(await outlined(page)).toBe("a");
    await page.close();
  });

  test("a deliberate move after the grace resumes hover-picking", async () => {
    const page = await open();
    await inspectFromMenu(page);
    await at(page, 20);
    await page.mouse.move(B.x, B.y + 1);
    await at(page, 700);
    await page.mouse.move(C.x, C.y, { steps: 3 });
    expect(await outlined(page)).toBe("c");
    await page.mouse.move(B.x, B.y, { steps: 3 });
    expect(await outlined(page)).toBe("b");
    await page.evaluate(([x, y]) => (window as any).picker.pick(x, y), [B.x, B.y]);
    const reports = await page.evaluate(() => (window as any).state.reports.map((r: any) => r.text_content));
    expect(reports).toEqual(["B, under the menu row"]);
    await page.close();
  });

  test("Inspect from a menu the page did not see falls back to the menu's own point", async () => {
    const page = await open();
    await page.evaluate(([x, y]) => (window as any).picker.inspectMenuTarget(x, y), [C.x, C.y]);
    expect(await outlined(page)).toBe("c");
    await page.close();
  });
});
