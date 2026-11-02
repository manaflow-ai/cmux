// l10n-allow-file: sample transcript and media labels, not shipped UI.
// Leo: "when I'm Control-Fing ... the chat shouldn't keep fucking jumping me back ... keeps
// taking me back to where I originally started". A Find match becomes the reader's new place.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser, type Page } from "playwright";
import { papercutPane, type PapercutStep } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-find-position.test.ts", async () => {
  setDefaultTimeout(180_000);
  let browser: Browser;
  let pane: Awaited<ReturnType<typeof papercutPane>>;
  const chunk = (text: string) => ({
    method: "session/update",
    params: {
      sessionId: "agent-1",
      update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } },
    },
  });
  const extra: PapercutStep[] = [];
  for (let turn = 1; turn <= 60; turn++) {
    const match = [4, 16, 28, 40, 52].indexOf(turn);
    extra.push(
      ["mux", "user_message", { text: match >= 0 ? `Checkpoint ${match + 1}` : `Question ${turn}` }],
      ["mux", "turn_started", {}],
      ["in", "agent_message_chunk", chunk(`Answer ${turn}: the checks on the merged head are green.`)],
      ["mux", "turn_result", { status: "completed" }],
    );
  }
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    pane = await papercutPane(() => browser, {
      turns: 0,
      running: false,
      extra,
      ready: ".acpmux-scroll .cv-user__bubble",
    });
  });
  afterAll(async () => {
    await browser?.close();
    await pane?.close();
  });

  const place = (page: Page) =>
    page.locator(".acpmux-scroll").evaluate((node) => {
      const view = node.getBoundingClientRect();
      const row = [...node.querySelectorAll<HTMLElement>(".acpmux-row")].find(
        (each) => each.getBoundingClientRect().bottom > view.top + 1,
      );
      return {
        top: node.scrollTop,
        height: node.scrollHeight,
        row: row?.dataset.rowId,
        offset: row ? row.getBoundingClientRect().top - view.top : 0,
      };
    });
  const frames = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<void>((resolve) => {
          let count = 0;
          window.cmuxAfterPaint(() => {
            if (++count < 45) return true;
            resolve();
            return false;
          });
        }),
    );
  const match = async (page: Page, count: string) => {
    await page.waitForFunction((count) => {
      if (document.querySelector(".find-pill__count")?.textContent !== count) return false;
      const range = [
        ...((CSS as unknown as { highlights: Map<string, Set<Range>> }).highlights.get("acpmux-find-active") ?? []),
      ][0];
      const view = document.querySelector(".acpmux-scroll")?.getBoundingClientRect();
      const box = range?.getBoundingClientRect();
      return box && view && box.height > 0 && box.top >= view.top && box.bottom <= view.bottom;
    }, count);
    await frames(page);
  };
  const capture = async (page: Page, name: string) => {
    const directory = process.env.NX_FIND_SCROLL_MEDIA_DIR;
    if (!directory) return;
    await mkdir(directory, { recursive: true });
    await page.screenshot({ path: `${directory}/${name}.png` });
  };
  const stays = async (page: Page, parked: Awaited<ReturnType<typeof place>>) => {
    await frames(page);
    const next = await place(page);
    expect(Math.abs(next.top - parked.top)).toBeLessThanOrEqual(1);
    expect(next.row).toBe(parked.row);
    expect(Math.abs(next.offset - parked.offset)).toBeLessThanOrEqual(1);
  };

  test("five distant matches keep their new place through close, query edits, Escape, stream and remeasure", async () => {
    const page = await pane.open({ width: 900, height: 700 });
    try {
      await frames(page);
      const original = await place(page);
      await page.locator(".acpmux-composer [contenteditable=true]").first().focus();
      await page.evaluate(() => window.cmuxAcpmuxBridge?.command?.("find"));
      const field = page.locator(".acpmux-find .find-pill__field");
      await field.fill("Checkpoint");
      await match(page, "1 of 5");
      const first = await place(page);
      await page.keyboard.press("Enter");
      await match(page, "2 of 5");
      const second = await place(page);
      await page.keyboard.press("Enter");
      await match(page, "3 of 5");
      const third = await place(page);
      expect(second.top - first.top).toBeGreaterThan(700);
      expect(third.top - second.top).toBeGreaterThan(700);
      expect(original.top - third.top).toBeGreaterThan(700);
      await capture(page, "third-match");

      // A query with no result chooses no new place. Close keeps the third match and restores
      // the intentional composer focus without scrolling it into view.
      await field.fill("No matching phrase anywhere");
      await page.waitForFunction(() => document.querySelector(".find-pill__count")?.textContent === "No results");
      await stays(page, third);
      await page.locator(".find-pill__button").last().click();
      await page.locator(".acpmux-find").waitFor({ state: "detached" });
      await stays(page, third);
      expect(
        await page
          .locator(".acpmux-composer [contenteditable=true]")
          .first()
          .evaluate((node) => node === document.activeElement),
      ).toBe(true);

      const beforeStream = await place(page);
      pane.record("user_message", { text: "Stream below the Find result" });
      pane.record("turn_started", {});
      pane.record("agent_message_chunk", chunk("A newly streamed answer below the parked reader."), "in");
      await page.waitForFunction(
        (height) => document.querySelector(".acpmux-scroll")!.scrollHeight > height,
        beforeStream.height,
      );
      await stays(page, third);
      await page.setViewportSize({ width: 920, height: 700 });
      await stays(page, third);
      await capture(page, "closed-after-stream");

      // A new query can navigate elsewhere; Escape parks that new match too.
      await page.evaluate(() => window.cmuxAcpmuxBridge?.command?.("find"));
      await field.fill("Checkpoint 4");
      await match(page, "1 of 1");
      const fourth = await place(page);
      expect(fourth.top - third.top).toBeGreaterThan(700);
      await page.keyboard.press("Escape");
      await page.locator(".acpmux-find").waitFor({ state: "detached" });
      await stays(page, fourth);

      // Ordinary reader movement and Jump to latest keep their existing controls.
      const scroller = page.locator(".acpmux-scroll");
      await scroller.hover({ position: { x: 80, y: 120 } });
      await page.mouse.wheel(0, -450);
      await page.waitForFunction((top) => document.querySelector(".acpmux-scroll")!.scrollTop < top - 100, fourth.top);
      await page.locator(".acpmux-jump-latest[data-shown]").click();
      await page.waitForFunction(() => {
        const node = document.querySelector(".acpmux-scroll")!;
        return node.scrollHeight - node.clientHeight - node.scrollTop <= 1;
      });
      console.log(
        `FIND_POSITION ${JSON.stringify({ original, first, second, third, fourth, final: await place(page) })}`,
      );
    } finally {
      await page.close();
    }
  });
});
