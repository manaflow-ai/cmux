// cmux-web-test-timeout: 900
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A chat drawn from the page's row store keeps every row on screen where it is (row 6d PR2, the
// architect's done-when lines and decision 377):
//
// - "zero visible-row shifts not caused by input, across open, reconnect, restart and page-up"
// - "a `window` of the same edition while the pane shows rows far above it: no row leaves, nothing
//   shifts, and exactly one `page` is asked, for the rows within two screens of the viewport and none
//   for the rest"
// - "a row whose rev changed is drawn as it is now" (an off-screen rev change makes no shift)
//
// A shift, as A0 defines it for every test: "a visible row's top moves more than 1 px between two
// painted frames with no input since the last one, and no visible row above it changed its own
// height in that frame." Every painted frame is read (support/storeChatHost.ts).
//
// The page is the pane's dev entry talking to a stand-in acpmux that advertises the hold, with a
// stand-in host for `chat.rows.*` that holds a generated chat of 3000 rows of varied heights (ids
// 1..3000) and answers each page PAGE_DELAY_MS late. Cases run in order on one page, then the
// restart on a second page opened at the place the first one kept:
//
// 1. open at the end; 2. page-up through several pages; 3. reconnect: a window of the same edition
// (`replaces: false`) at the end while the pane reads far above; 5. a rev change of a row above the
// viewport; 4. restart at the kept place (`chat.scrollAnchor`), opened `around` its row.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import {
  installStoreChatHost,
  isReply,
  rowPages,
  storeChat,
  storeChatDaemon,
  storeChatRows,
  storeChatSummary,
  type KeptPlace,
  type ShiftTake,
} from "./support/storeChatHost";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-store-chat-shifts.test.ts", async () => {
  setDefaultTimeout(600_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`transcript-store-chat-shifts: skipping ${engine[0]}`);
    }
  }
  if (engines.length === 0) {
    describe.skip("store chat shifts", () => test("no engine", () => {}));
    return;
  }

  const CHAT = "0190a000-0000-7000-8000-00000000d6d2";
  const TURNS = 1000;
  const ROWS = 3 * TURNS;
  /// The rows a window holds (acpmux-client chat.rs MAX_CHAT_ROWS) and a page gives.
  const WINDOW_ROWS = 400;
  const PAGE_ROWS = 200;
  /// An older page lands this late.
  const PAGE_DELAY_MS = 400;
  /// The older pages that must land under the reader for page-up to count.
  const PAGES = 4;
  /// rows/chatSource.ts `REREAD_SCREENS` and its line (`LINE_PX`): a screen is the window's height
  /// over 20 px lines, in the store's `est` unit. Not imported: chatSource.ts reaches direct.ts.
  const REREAD_SCREENS = 2;
  const LINE_PX = 20;
  const VIEWPORT = { width: 1100, height: 800 };
  const rows = storeChatRows(TURNS);
  const est = new Map(rows.map((row) => [row.id, row.est]));

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let daemon: ReturnType<typeof storeChatDaemon> | undefined;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    daemon = storeChatDaemon(storeChatSummary(CHAT, TURNS));
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
    await daemon?.stop();
  });

  const address = () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(daemon!.endpoint)}&token=t&session=${CHAT}`;
  };

  async function openPane(browser: Browser, kept: KeptPlace | null, errors: string[]): Promise<Page> {
    const page = await browser.newPage({ viewport: VIEWPORT });
    page.on("pageerror", (error) => errors.push(error.message));
    await installPaintedFrames(page);
    await installStoreChatHost(page, {
      chat: CHAT,
      rows,
      windowRows: WINDOW_ROWS,
      pageRows: PAGE_ROWS,
      pageDelayMs: PAGE_DELAY_MS,
      kept,
    });
    await page.goto(address());
    return page;
  }

  /// The shifts a case saw, in one line for the log.
  const described = (take: ShiftTake) =>
    take.shifts
      .slice(0, 8)
      .map(
        (shift) =>
          `${shift.rowId} moved ${shift.moved.toFixed(1)} px from ${shift.top.toFixed(0)} at frame ${shift.frame}`,
      );

  /// The store's height of the rows `from..to`, in lines.
  const linesOf = (from: number, to: number) => {
    let lines = 0;
    for (let id = from; id <= to; id++) lines += est.get(id) ?? 0;
    return lines;
  };

  const rowNumber = (rowId: string | null | undefined) => {
    const match = rowId ? /^row-(\d+)$/.exec(rowId) : null;
    return match ? Number(match[1]) : NaN;
  };

  for (const [name] of engines)
    test(`${name}: a store chat keeps its rows still across open, page-up, reconnect, rev change, restart`, async () => {
      const errors: string[] = [];
      const browser = browsers.get(name)!;
      const attachesBefore = daemon!.attaches.length;
      const page = await openPane(browser, null, errors);
      const chat = storeChat(page);
      let restarted: Page | undefined;
      try {
        // 1. Open at the end.
        await page.locator(`.acpmux-row[data-row-id="row-${ROWS - 1}"]`).waitFor({ timeout: 120_000 });
        await chat.settle();
        const open = await chat.take();
        const opens = (await chat.posts()).filter((post) => post.method === "chat.rows.open");
        const atEnd = (await chat.visible()).some((row) => row.id === `row-${ROWS - 1}`);
        console.log(
          `transcript-store-chat-shifts ${name} open: ${JSON.stringify({ frames: open.frames, shifts: open.count, first: described(open), opens: opens.map((post) => post.params.anchor) })}`,
        );
        // The chat is on the store: it opened a sub at the end and attached as the hold.
        expect(opens.map((post) => post.params.anchor)).toEqual(["end"]);
        expect(daemon!.attaches.slice(attachesBefore).some((params) => params.hold === true)).toBe(true);
        expect(atEnd).toBe(true);
        expect(open.count).toBe(0);

        // 2. Page-up: rounds of wheel up, each followed by no input while the pages out land.
        const pagesBefore = rowPages(await chat.posts()).length;
        let olderPages = 0;
        let pageUp = { frames: 0, count: 0, shifts: [] as ShiftTake["shifts"] };
        for (let round = 0; round < 40 && olderPages < PAGES; round++) {
          await chat.wheel(Array.from({ length: 24 }, (_, step) => -[110, 160, 135, 185][step % 4]!));
          await chat.settle();
          const take = await chat.take();
          pageUp = {
            frames: pageUp.frames + take.frames,
            count: pageUp.count + take.count,
            shifts: [...pageUp.shifts, ...take.shifts],
          };
          olderPages = rowPages(await chat.posts())
            .slice(pagesBefore)
            .filter((post) => typeof post.params.before === "number").length;
        }
        const topAfterUp = rowNumber((await chat.visible())[0]?.id);
        console.log(
          `transcript-store-chat-shifts ${name} page-up: ${JSON.stringify({ pages: olderPages, frames: pageUp.frames, shifts: pageUp.count, first: described({ ...pageUp, firstSeen: {} }), top: topAfterUp })}`,
        );
        expect(olderPages).toBeGreaterThanOrEqual(PAGES);
        expect(topAfterUp).toBeLessThan(ROWS - WINDOW_ROWS);
        expect(pageUp.count).toBe(0);

        // 3. Reconnect: a window of the same edition at the end, not in place of the rows held, while
        // the pane reads far above it. Its rows held outside it are unconfirmed; those within two
        // screens of the reading place are asked for in one page.
        // The reading place the pane reported once page-up settled (App.tsx `onAnchor` -> `restAt`, and
        // the host's `chat.scrollAnchor`): its row is on screen.
        await page.waitForFunction(
          () => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
            const kept = (window as any).__storeChat.kept() as { rowId: string | null } | null;
            const row = kept?.rowId ? scroller?.querySelector<HTMLElement>(`[data-row-id="${kept.rowId}"]`) : null;
            if (!scroller || !row) return false;
            const view = scroller.getBoundingClientRect();
            const box = row.getBoundingClientRect();
            return box.bottom > view.top && box.top < view.bottom;
          },
          null,
          { timeout: 30_000 },
        );
        const reading = rowNumber((await chat.kept())?.rowId);
        const windowFirst = ROWS - WINDOW_ROWS + 1;
        expect(reading).toBeLessThan(windowFirst - 100);
        const shownBefore = (await chat.visible()).map((row) => row.id);
        const postsBefore = (await chat.posts()).length;
        await chat.take();
        await chat.sendWindow("end", false);
        await chat.settle();
        const reconnect = await chat.take();
        const asked = rowPages((await chat.posts()).slice(postsBefore));
        const left = await page.evaluate(
          (ids) => ids.filter((id) => !document.querySelector(`.acpmux-scroll [data-row-id="${id}"]`)),
          shownBefore,
        );
        const screen = Math.ceil((await page.evaluate(() => window.innerHeight)) / LINE_PX);
        const reach = REREAD_SCREENS * screen;
        const before = asked[0]?.params.before as number | undefined;
        console.log(
          `transcript-store-chat-shifts ${name} reconnect: ${JSON.stringify({ reading, asked: asked.map((post) => post.params), reach, linesToAsked: before === undefined ? null : linesOf(reading, before - 2), frames: reconnect.frames, shifts: reconnect.count, first: described(reconnect), left })}`,
        );
        expect(reconnect.count).toBe(0);
        expect(left).toEqual([]);
        // Exactly one page, and none for the rest once it landed (settle waited for it).
        expect(asked.length).toBe(1);
        // A page before the newest unconfirmed row within two screens of the reading place: that
        // row (`before - 1`) lies at or past the reading row, no further than the reach
        // (chatSource.ts `reconfirm` stops adding rows once their lines pass it).
        expect(typeof before).toBe("number");
        expect(before! - 1).toBeGreaterThanOrEqual(reading);
        expect(before! - 1).toBeLessThan(windowFirst);
        expect(linesOf(reading, before! - 2)).toBeLessThanOrEqual(reach);

        // 5. A rev change: a reply above the viewport settles again, a few lines taller. Nothing on
        // screen moves, and the row is drawn as it is now.
        const firstShown = rowNumber((await chat.visible())[0]?.id);
        const mountedAbove = await page.evaluate(() => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const view = scroller.getBoundingClientRect();
          return [...scroller.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")]
            .filter((row) => row.getBoundingClientRect().bottom <= view.top)
            .map((row) => row.dataset.rowId!);
        });
        const aboveIds = mountedAbove.map(rowNumber).filter((id) => Number.isFinite(id) && isReply(id));
        // A reply drawn above the viewport when the list draws one there; else one held a few turns up.
        let target = aboveIds.length ? Math.max(...aboveIds) : firstShown - 9;
        while (!isReply(target)) target -= 1;
        const marker = `Edited ${target}: the second run of the checks found one more flaky case.`;
        await chat.take();
        await chat.patch(target, `${marker}\n\n${marker}\n\n${marker}`);
        await chat.settle();
        const revised = await chat.take();
        const drawn = await page.evaluate(
          (id) => document.querySelector(`.acpmux-scroll [data-row-id="row-${id}"]`)?.textContent ?? null,
          target,
        );
        console.log(
          `transcript-store-chat-shifts ${name} rev change: ${JSON.stringify({ target, mountedAbove: aboveIds.length, drawnNow: drawn?.includes(marker) ?? null, frames: revised.frames, shifts: revised.count, first: described(revised) })}`,
        );
        expect(revised.count).toBe(0);
        if (drawn !== null) expect(drawn).toContain(marker);
        expect(await chat.errors()).toEqual([]);

        // 4. Restart: a new page opens at the place the host kept, around its row.
        await chat.settle();
        const kept = await chat.kept();
        expect(kept?.rowId).toMatch(/^row-\d+$/);
        const keptTop = (await chat.visible()).find((row) => row.id === kept!.rowId)?.top;
        expect(keptTop).toBeDefined();
        await page.close();
        restarted = await openPane(browser, { rowId: kept!.rowId!, offset: kept!.offset }, errors);
        const again = storeChat(restarted);
        // The open is read first: one at the end would never draw the kept row.
        await restarted.waitForFunction(
          () =>
            ((window as any).__storeChat.host.posts as { method: string }[]).some(
              (post) => post.method === "chat.rows.open",
            ),
          null,
          { timeout: 60_000 },
        );
        const reopens = (await again.posts()).filter((post) => post.method === "chat.rows.open");
        expect(reopens[0]?.params.anchor).toEqual({ rowId: rowNumber(kept!.rowId), side: "around" });
        await restarted.locator(`.acpmux-row[data-row-id="${kept!.rowId}"]`).waitFor({ timeout: 120_000 });
        await again.settle();
        const restart = await again.take();
        const placedAt = restart.firstSeen[kept!.rowId!];
        const afterPlaced = restart.shifts.filter((shift) => placedAt !== undefined && shift.frame > placedAt);
        const topNow = (await again.visible()).find((row) => row.id === kept!.rowId)?.top;
        console.log(
          `transcript-store-chat-shifts ${name} restart: ${JSON.stringify({ kept, keptTop, topNow, placedAt, opens: reopens.map((post) => post.params.anchor), frames: restart.frames, shifts: restart.count, first: described(restart) })}`,
        );
        // The watch lists the first 40 shifts: more than that fails before they are read by frame.
        expect(restart.count).toBe(restart.shifts.length);
        expect(placedAt).toBeDefined();
        expect(afterPlaced).toEqual([]);
        expect(Math.abs(topNow! - keptTop!)).toBeLessThanOrEqual(1);
        expect(await again.errors()).toEqual([]);
        expect(errors).toEqual([]);
      } finally {
        if (!page.isClosed()) await page.close();
        await restarted?.close();
      }
    });
});
