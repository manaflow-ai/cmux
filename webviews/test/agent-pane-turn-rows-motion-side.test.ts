// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Two transcript papercuts Leo hit on the nightly (2026-10-19):
// - A running tool's ring (icons.tsx Spinner: "Running 2 commands", a command's meta) never
//   turned: nothing animated it. It turns now, and holds still under Reduce Motion or the Static
//   status indicators.
// - A turn's footer ("Worked for 2s · 4:44 PM", Copy, Retry) sat at the column's right edge, under
//   where the user's bubble sits. It belongs to the agent's answer, so it starts at the answer's
//   left edge.
//
// The pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// (support/papercutChat.ts). Real Chromium and WebKit (the app's engine) from Playwright; CI fails
// the file when it cannot launch them (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/agent-pane-turn-rows-motion-side.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane } from "./support/papercutChat";

await requireBrowserLane("agent-pane-turn-rows-motion-side.test.ts", async () => {
  setDefaultTimeout(300_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`agent-pane-turn-rows-motion-side: skipping ${engine[0]}`);
    }
  }
  if (engines.length === 0) {
    describe.skip("turn rows", () => test("browsers", () => {}));
    return;
  }
  const browsers = new Map<string, Browser>();
  let current: Browser | undefined;
  // Three finished turns, then one running two commands.
  let running: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    running = await papercutPane(() => current!, { turns: 3, running: true });
    // The first load can run Vite's dependency optimizer and reload mid-compile.
    current = browsers.values().next().value;
    await (await running.open()).close();
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await running?.close();
  });

  /// Each running ring's rotation, sampled `ms` apart.
  const ringAngles = (page: Page) =>
    page.evaluate(() =>
      [...document.querySelectorAll<SVGElement>(".cv-tool svg.cv-spinner")].map((ring) => {
        const matrix = new DOMMatrix(getComputedStyle(ring).transform);
        return Math.round((Math.atan2(matrix.b, matrix.a) * 180) / Math.PI);
      }),
    );

  for (const [name] of engines) {
    describe(name, () => {
      test("a running tool's ring turns", async () => {
        current = browsers.get(name);
        const page = await running!.open();
        await page.getByText("Running 2 commands", { exact: false }).first().waitFor();
        const first = await ringAngles(page);
        expect(first.length).toBeGreaterThan(0);
        await page.waitForTimeout(170);
        const second = await ringAngles(page);
        expect(second.length).toBe(first.length);
        // Each ring moved between the samples.
        for (let index = 0; index < first.length; index++) expect(second[index]).not.toBe(first[index]);
        await page.close();
      });

      test("Reduce Motion and the Static indicators hold the ring still", async () => {
        current = browsers.get(name);
        const page = await running!.open();
        await page.getByText("Running 2 commands", { exact: false }).first().waitFor();
        await page.emulateMedia({ reducedMotion: "reduce" });
        const reduced = await page.evaluate(() =>
          [...document.querySelectorAll<SVGElement>("svg.cv-spinner")].map(
            (ring) => getComputedStyle(ring).animationName,
          ),
        );
        expect(reduced.length).toBeGreaterThan(0);
        expect(reduced.every((animation) => animation === "none")).toBe(true);
        await page.emulateMedia({ reducedMotion: "no-preference" });
        await page.evaluate(() => (document.documentElement.dataset.statusIndicators = "static"));
        const still = await page.evaluate(() =>
          [...document.querySelectorAll<SVGElement>("svg.cv-spinner")].map(
            (ring) => getComputedStyle(ring).animationName,
          ),
        );
        expect(still.every((animation) => animation === "none")).toBe(true);
        await page.close();
      });

      test("a turn's footer starts at its answer's left edge", async () => {
        current = browsers.get(name);
        const page = await running!.open();
        const placed = await page.evaluate(() => {
          const rows = [...document.querySelectorAll<HTMLElement>(".acpmux-row")].sort(
            (a, b) => Number(a.getAttribute("aria-posinset")) - Number(b.getAttribute("aria-posinset")),
          );
          const footer = rows.filter((row) => row.querySelector(".cv-turn-actions")).at(-1)!;
          const answer = rows.filter((row) => row.textContent?.includes("Answer 3:")).at(-1)!;
          const text = [...answer.querySelectorAll<HTMLElement>("p, .cv-md")].find((node) =>
            node.textContent?.startsWith("Answer 3:"),
          )!;
          const worked = footer.querySelector(".cv-turn-actions")!.firstElementChild!.getBoundingClientRect();
          const user = [...document.querySelectorAll<HTMLElement>(".cv-user, .cv-user__bubble")]
            .at(-1)
            ?.getBoundingClientRect();
          return {
            worked: { left: worked.left, right: worked.right },
            answerLeft: text.getBoundingClientRect().left,
            column: answer.getBoundingClientRect().right,
            userRight: user?.right,
            label: footer.querySelector(".cv-turn-actions")!.firstElementChild!.textContent,
          };
        });
        expect(placed.label).toMatch(/^Worked for/);
        // Its first piece starts where the answer's text starts, within a couple of pixels.
        expect(Math.abs(placed.worked.left - placed.answerLeft)).toBeLessThanOrEqual(3);
        await page.close();
      });
    });
  }
});
