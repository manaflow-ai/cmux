// l10n-allow-file: test fixture replies, not shipped UI.
// A notification row and the agent's reply after it, in Chromium (gallery agent-pane.notification-reply,
// which replays acpmux's events through the pane's own client). Leo, 2026-11-09 20:33Z: "these
// rendered previews dont have time... maybe they dont have other things too / and your response was
// weirdly folded into the rende?". Opened, a "Subagent finished" row keeps every field its shut line
// has (its mark, its name chip, its new dot, its time, its chevron), each drawn on the line; and the
// agent's own reply after a subagent's or a background command's end draws as the agent's own
// message, outside the row's box, never as a muted paragraph inside it.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { AGENT, COMMAND_REPLY, REPLY } from "../src/agent-session/acpmux/conversation/NotificationReply.gallery";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("notification-reply-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.notification-reply";

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("notification reply", () => test("browser", () => {}));
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "collapsed" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (variant: string, width = 900): Promise<Page> => {
    const page = await browser.newPage({ viewport: { width: width + 100, height: 900 }, deviceScaleFactor: 2 });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width, theme: "Catppuccin Mocha", reducedMotion: "true" })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    await page.mouse.move(0, 0);
    return page;
  };
  const settled = (page: Page) =>
    page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));

  type Field = { shown: boolean; text: string; onLine: boolean; inRow: boolean };
  /** Each field of the subagent's line: drawn, on the line's own 22px band, inside the row's box. */
  const fields = (page: Page) =>
    page.evaluate((agent) => {
      const row = document.querySelector<HTMLElement>(`.acpmux-row[data-row-id="subagentDone:${agent}"]`);
      const line = row?.querySelector<HTMLElement>(".cv-agentmsg__line");
      const lineBox = line?.getBoundingClientRect();
      const rowBox = row?.getBoundingClientRect();
      const field = (selector: string) => {
        const node = line?.querySelector<HTMLElement>(selector);
        const box = node?.getBoundingClientRect();
        const shown =
          !!node && !!box && box.width > 0 && box.height > 0 && node.checkVisibility({ visibilityProperty: true });
        const mid = box ? (box.top + box.bottom) / 2 : NaN;
        return {
          shown,
          text: node?.textContent?.trim() ?? "",
          onLine: !!lineBox && mid >= lineBox.top && mid <= lineBox.top + 22,
          inRow: !!rowBox && !!box && box.left >= rowBox.left - 0.5 && box.right <= rowBox.right + 0.5,
        };
      };
      return {
        found: !!line,
        open: row?.querySelector(".cv-agentmsg")?.hasAttribute("data-open") ?? false,
        icon: field(".cv-agentmsg__icon"),
        name: field(".cv-agentmsg__name"),
        mark: field(".cv-reaction-mark"),
        time: field(".cv-agentmsg__time"),
        chevron: field(".cv-agentmsg__chevron"),
      };
    }, AGENT);

  /** Where `words` draw: in which transcript row, whether inside the row of `notification`. */
  const placed = (page: Page, words: string, notification: string) =>
    page.evaluate(
      ({ words, notification }) => {
        const holder = document.querySelector(notification);
        const node = [...document.querySelectorAll<HTMLElement>(".acpmux-row p, .acpmux-row .cv-reaction-reply")].find(
          (each) => each.textContent?.trim().startsWith(words),
        );
        const row = node?.closest<HTMLElement>(".acpmux-row[data-row-id]");
        const holderBox = holder?.closest(".acpmux-row")?.getBoundingClientRect();
        const box = node?.getBoundingClientRect();
        return {
          found: !!node,
          insideNotification: !!holder && !!node && (holder.closest(".acpmux-row")?.contains(node) ?? false),
          muted: node?.classList.contains("cv-reaction-reply") ?? false,
          row: row?.dataset.rowId ?? null,
          below: !!box && !!holderBox && box.top >= holderBox.bottom - 0.5,
        };
      },
      { words, notification },
    );

  const expectFields = (state: string, result: Awaited<ReturnType<typeof fields>>) => {
    const why = `${state}: ${JSON.stringify(result)}`;
    expect(result.found, why).toBe(true);
    for (const key of ["icon", "name", "mark", "time", "chevron"] as const) {
      const one = result[key] as Field;
      expect(one.shown, `${why}\n${key} not shown`).toBe(true);
      expect(one.onLine, `${why}\n${key} off the line`).toBe(true);
      expect(one.inRow, `${why}\n${key} outside the row`).toBe(true);
    }
    expect(result.time.text, why).toMatch(/^\d+m \d+s$/);
  };

  // A wide pane, a chat column and a narrow one: the opened line's name may wrap, never push its
  // time or dot out. Pointed at, too: the hover row never takes their place.
  for (const width of [900, 560, 380])
    test(`an opened Subagent finished row keeps its mark, name, new dot, time and chevron on its line at ${width}px`, async () => {
      const page = await open("collapsed", width);
      const shut = await fields(page);
      expectFields("shut", shut);
      expect(shut.open).toBe(false);
      // The line's words open it, as a click anywhere on the line does (headerToggle.ts): in a narrow
      // pane its first line, the toggle's own box, has given all its room away.
      const words = page.locator(`.acpmux-row[data-row-id="subagentDone:${AGENT}"] .cv-agentmsg__words`).first();
      await words.click();
      await page.waitForSelector(".cv-subagent-done__report");
      await settled(page);
      const opened = await fields(page);
      expect(opened.open).toBe(true);
      expectFields(`opened at ${width}`, opened);
      // The same time, open or shut.
      expect(opened.time.text).toBe(shut.time.text);
      await words.hover();
      await settled(page);
      expectFields(`opened and pointed at, at ${width}`, await fields(page));
      await page.close();
    });

  test("the agent's reply after a subagent's end is its own message, open or shut", async () => {
    const page = await open("collapsed");
    const row = `.acpmux-row[data-row-id="subagentDone:${AGENT}"]`;
    const shut = await placed(page, REPLY.slice(0, 40), row);
    expect(shut, JSON.stringify(shut)).toMatchObject({
      found: true,
      insideNotification: false,
      muted: false,
      below: true,
    });
    await page.locator(`${row} .cv-agentmsg__toggle`).click();
    await page.waitForSelector(".cv-subagent-done__report");
    await settled(page);
    const opened = await placed(page, REPLY.slice(0, 40), row);
    expect(opened, JSON.stringify(opened)).toMatchObject({
      found: true,
      insideNotification: false,
      muted: false,
      below: true,
    });
    await page.close();
  });

  test("the agent's reply after a background command's end is its own message, not under the call", async () => {
    const page = await open("command-reply");
    const reply = await placed(page, COMMAND_REPLY.slice(0, 30), ".acpmux-row .cv-tools");
    expect(reply, JSON.stringify(reply)).toMatchObject({ found: true, muted: false });
    expect(await page.locator(".cv-reaction-reply").count()).toBe(0);
    await page.close();
  });

  test("a notification with no reply draws its row alone", async () => {
    const page = await open("no-reply");
    expectFields("no reply", await fields(page));
    expect(await page.locator(".cv-reaction-reply").count()).toBe(0);
    await page.close();
  });
});
