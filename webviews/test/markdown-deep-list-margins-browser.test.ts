// A list nested at any depth keeps its spacing under block containment. Each top-level block of the
// markdown page has `contain: layout style` (styles.css), which stops its children's margins
// collapsing through its edges, so a top-level list takes its items' margins itself and the
// elements whose margins used to collapse out through its top or bottom edge drop theirs. That
// was written one selector per level down five list levels: from six levels down, the deepest
// item's 4 px margin stayed inside the list, and the text after the list started 4 px lower.
//
// The real page (markdown-page.html) on the dev server, through the stand-in host the bench uses,
// in Chromium and WebKit (the app's engine): for lists nested 1 to 12 levels deep, the distance
// from the paragraph before each list to the paragraph after it is the same with the containment
// as without it (`contain: none` on the top-level blocks, which is how the page laid out before
// it). In each list every level ends its item: bullet, ordered, and `- - - deepest` (each item
// but the deepest one has an empty first line). At 6326799e (five levels of selectors) the text
// after the list was 4 px lower from six levels down, in both engines.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import type { BrowserType, Page } from "playwright";
import { chromium, webkit } from "../bench/browsers";
import { serveBenchPage, type BenchPage } from "../bench/support/benchPage";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("markdown-deep-list-margins-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`markdown-deep-list-margins: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("markdown deep list margins", () => test("no engine", () => {}));
    return;
  }

  let served: BenchPage | undefined;
  beforeAll(async () => {
    served = await serveBenchPage("/markdown-page.html", { dev: true });
  }, 120_000);
  afterAll(async () => {
    await served?.close();
  });

  const DEPTHS = Array.from({ length: 12 }, (_, i) => i + 1);
  const BOTTOM = "deep-lists-bottom";
  const CASES: Record<string, (depth: number) => string> = {
    bullet: (depth) =>
      DEPTHS.slice(0, depth)
        .map((level) => `${"  ".repeat(level - 1)}- level ${level}`)
        .join("\n"),
    ordered: (depth) =>
      DEPTHS.slice(0, depth)
        .map((level) => `${"   ".repeat(level - 1)}1. level ${level}`)
        .join("\n"),
    "nested first": (depth) => `${"- ".repeat(depth)}deepest`,
  };
  const fixture = () => {
    let text = "# Deep lists\n\n";
    for (const [name, list] of Object.entries(CASES))
      for (const depth of DEPTHS) text += `before ${name} ${depth}\n\n${list(depth)}\n\nafter ${name} ${depth}\n\n`;
    return `${text}${BOTTOM}\n`;
  };

  /** The stand-in host (bench/markdown-keystroke.bench.ts's): the file comes from `/__fixture`. */
  function installHost(): void {
    type Envelope = { t: string; id?: number; op?: string };
    let nextSub = 1;
    const postMessage = async (message: Envelope): Promise<unknown> => {
      if (message.t === "sub") return { t: "ok", id: message.id, value: { sub: nextSub++ } };
      if (message.t !== "call") return null;
      if (message.op === "cmux.markdown.config") {
        const text = await (await fetch("/__fixture", { cache: "no-store" })).text();
        return { t: "ok", id: message.id, value: { path: "/test/deep-lists.md", text, hash: `h${text.length}` } };
      }
      return { t: "ok", id: message.id, value: {} };
    };
    (window as unknown as { webkit: unknown }).webkit = { messageHandlers: { cmuxPage: { postMessage } } };
  }

  const painted = (page: Page) =>
    page.evaluate(
      () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve(null)))),
    );

  /** Per "<case> <depth>": the distance from the paragraph before the list to the one after it. */
  const gaps = (page: Page) =>
    page.evaluate(() => {
      const tops = new Map<string, number>();
      for (const block of document.querySelector(".md-prose")!.children) {
        const text = block.textContent?.trim() ?? "";
        if (/^(before|after) /.test(text)) tops.set(text, block.getBoundingClientRect().top);
      }
      const out: Record<string, number> = {};
      for (const [text, top] of tops)
        if (text.startsWith("after ")) out[text.slice(6)] = top - tops.get(`before ${text.slice(6)}`)!;
      return out;
    });

  for (const [name, engine] of engines) {
    test(`${name}: the text after a list nested 1 to 12 levels deep is where it is without containment`, async () => {
      const browser = await engine.launch({ headless: true });
      try {
        const page = await browser.newPage({ viewport: { width: 1000, height: 900 } });
        await page.route("**/__fixture", (route) =>
          route.fulfill({ status: 200, contentType: "text/markdown", body: fixture() }),
        );
        await page.addInitScript(installHost);
        await page.goto(served!.url);
        await page.waitForFunction(
          (bottom) => !!document.querySelector(".md-prose")?.lastElementChild?.textContent?.includes(bottom),
          BOTTOM,
          { timeout: 180_000, polling: 200 },
        );
        await page.evaluate(() => document.fonts.ready.then(() => null));
        await painted(page);

        const contained = await page.evaluate(() =>
          [...document.querySelectorAll(".md-prose > :is(ul, ol)")].every((list) =>
            getComputedStyle(list).contain.includes("layout"),
          ),
        );
        expect(contained).toBe(true);
        const withContainment = await gaps(page);
        await page.addStyleTag({ content: ".md-prose > * { contain: none !important; }" });
        await painted(page);
        const withoutContainment = await gaps(page);

        const expected = Object.keys(CASES).flatMap((caseName) => DEPTHS.map((depth) => `${caseName} ${depth}`));
        expect(Object.keys(withoutContainment).sort()).toEqual([...expected].sort());
        const shift: Record<string, number> = {};
        for (const key of expected)
          shift[key] = Math.round((withContainment[key]! - withoutContainment[key]!) * 100) / 100;
        expect(shift).toEqual(Object.fromEntries(expected.map((key) => [key, 0])));
      } finally {
        await browser.close();
      }
    });
  }
});
