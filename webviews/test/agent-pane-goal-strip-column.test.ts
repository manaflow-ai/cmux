// cmux-web-test-timeout: 900
// l10n-allow-file: test labels, not shipped UI.
// cmux#38051: the goal row over the composer (TaskGoalStrip.tsx) stands in the composer's column,
// on the card's two edges, at every pane width. It was a band the pane's width wide (padding by the
// page edge only), so in a wide pane a Claude Code loop's wake prompt ran past the transcript's
// column from one side of the pane to the other. And a self-wake loop shows only when it checks
// back: its prompt (job ids, links, steps) never paints, opened or not, outside the column.
//
// Real gallery frames (agent-pane.composer-look) in real Chromium from Playwright; CI fails the file
// when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Edges = { left: number; right: number };
type Measured = { goal: Edges; composer: Edges; text: string; details: Edges | null };

await requireBrowserLane("agent-pane-goal-strip-column.test.ts", async () => {
  setDefaultTimeout(840_000);
  const ENTRY = "agent-pane.composer-look";
  // A wide pane (the column is capped, so the gutters are wide), a normal one, a narrow one and one
  // under the composer's 298px narrow outset (--acpmux-stack-outset).
  const WIDTHS = [1800, 900, 420, 300];
  const VARIANTS = ["loop-wakeup", "loop-wakeup-open", "loop-cron", "goal-stalled", "claude-loop-steps"];
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, [ENTRY], { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function open(variant: string, width: number): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width, height: 620 } });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width })}`);
    await page.locator(".acpmux-composer-box").first().waitFor({ timeout: 90_000 });
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 60_000,
    });
    await page.locator(".acpmux-dock > .acpmux-goal").first().waitFor({ timeout: 30_000 });
    return page;
  }

  function measure(): Measured {
    const edges = (el: Element) => {
      const r = el.getBoundingClientRect();
      return { left: r.left, right: r.right };
    };
    const goal = document.querySelector(".acpmux-dock > .acpmux-goal")!;
    const details = goal.querySelector<HTMLElement>(".acpmux-goal-details");
    return {
      goal: edges(goal),
      composer: edges(document.querySelector(".acpmux-composer-box")!),
      // What paints in the row: the chip, without the details a click opens.
      text: [...goal.childNodes]
        .filter((node) => !(node instanceof HTMLElement && node.classList.contains("acpmux-goal-details")))
        .map((node) => node.textContent ?? "")
        .join("")
        .trim(),
      details: details ? edges(details) : null,
    };
  }

  test("the goal row takes the composer card's edges at every width, and a loop shows no wake prompt", async () => {
    const offenders: string[] = [];
    for (const width of WIDTHS) {
      for (const variant of VARIANTS) {
        const page = await open(variant, width);
        try {
          const m = await page.evaluate(measure);
          const where = `${variant} @ ${width}px`;
          if (Math.abs(m.goal.left - m.composer.left) > 1 || Math.abs(m.goal.right - m.composer.right) > 1)
            offenders.push(
              `${where}: goal ${m.goal.left}..${m.goal.right}, composer ${m.composer.left}..${m.composer.right}`,
            );
          if (variant.startsWith("loop-wakeup")) {
            // The gallery clock runs from GALLERY_NOW once the frame loads: a slow load can round to 14.
            if (!/^Checking back in 1[45] min\.$/.test(m.text)) offenders.push(`${where}: the chip reads "${m.text}"`);
            if (/b2mqa7gwr|github\.com|Steps:/.test(m.text))
              offenders.push(`${where}: the wake prompt paints in the row`);
          }
          if (variant === "loop-cron" && m.text !== "Repeats every 5 minutes")
            offenders.push(`${where}: the chip reads "${m.text}"`);
          if (variant === "loop-wakeup-open") {
            if (!m.details) offenders.push(`${where}: the prompt did not open on demand`);
            else if (m.details.left < m.goal.left - 1 || m.details.right > m.goal.right + 1)
              offenders.push(`${where}: the opened prompt ${m.details.left}..${m.details.right} leaves the row`);
          }
        } finally {
          await page.close();
        }
      }
    }
    expect(offenders).toEqual([]);
  });
});
