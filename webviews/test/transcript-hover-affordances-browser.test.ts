// cmux-web-test-timeout: 400
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Every hover affordance in a transcript row answers the pointer in the real pane (Leo, 2026-11-19:
// "the hovering for timestamps and links previews in transcript is not urrently working right
// now?"). The page is the pane's dev entry on a stand-in acpmux daemon with finished turns. For each
// affordance the pointer moves onto it as a person's does, and the test reads back what the person
// sees: the element under the pointer is the affordance itself (no layer above it takes the
// pointer), a time in a reply and a prompt's time open their exact-date tooltip, a link's preview
// card opens, a reply's actions show while its row is pointed at, and Copy names itself. Each runs
// on an idle chat and while a turn streams. Real Chromium and WebKit (WebKit draws the pane in cmux
// NEXT's WebKit fallback; Chromium by default).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane } from "./support/papercutChat";

await requireBrowserLane("transcript-hover-affordances-browser.test.ts", async () => {
  setDefaultTimeout(300_000);
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as const) {
    describe(`${name}, an idle chat`, () => engineHovers(engine, false));
    describe(`${name}, while a turn streams`, () => engineHovers(engine, true));
  }
});

function engineHovers(engine: BrowserType, streaming: boolean) {
  let browser: Browser;
  let pane: Awaited<ReturnType<typeof papercutPane>>;
  let page: Page;
  let stream: ReturnType<typeof setInterval> | undefined;
  beforeAll(async () => {
    browser = await engine.launch({ headless: true });
    pane = await papercutPane(() => browser, {
      turns: 2,
      running: streaming,
      answer: (n) => `Answer ${n}: the checks went green at 05:21Z, see https://example.com/checks/${n} for the run.`,
      ...(streaming && { ready: ".acpmux-scroll .cv-time-hover" }),
    });
    page = await pane.open({ width: 900, height: 700 });
    if (!streaming) return;
    // The live turn's thinking and its command's output, every 40 ms, as a running agent sends them.
    const update = (body: Record<string, unknown>) => ({
      method: "session/update",
      params: { sessionId: "agent-1", update: body },
    });
    let tick = 0;
    stream = setInterval(() => {
      tick++;
      pane.record(
        "agent_thought_chunk",
        update({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text: `thinking ${tick} ` } }),
        "in",
      );
      if (tick % 3 === 0)
        pane.record(
          "tool_call_update",
          update({
            sessionUpdate: "tool_call_update",
            toolCallId: "r2",
            status: "in_progress",
            content: [{ type: "content", content: { type: "text", text: `line ${tick}\n` } }],
          }),
          "in",
        );
    }, 40);
    // The live line's first chunks grow the chat once, and the followed transcript scrolls by that
    // much: hovers start once its scroll has held for half a second.
    await page.locator(".acpmux-scroll").evaluate(async (scroller) => {
      let last = -1;
      let since = performance.now();
      while (performance.now() - since < 500) {
        await new Promise((resolve) => requestAnimationFrame(resolve));
        if (scroller.scrollTop !== last) [last, since] = [scroller.scrollTop, performance.now()];
      }
    });
  });
  afterAll(async () => {
    if (stream) clearInterval(stream);
    await page?.close();
    await pane?.close();
    await browser?.close();
  });

  /// Moves the pointer onto `selector`'s last match in steps, as a hand does, and says what the page
  /// hit-tests there.
  const pointAt = async (selector: string) => {
    await page.mouse.move(5, 5);
    const box = await page.locator(selector).last().boundingBox();
    if (!box) throw new Error(`no box for ${selector}`);
    const x = box.x + box.width / 2;
    const y = box.y + box.height / 2;
    await page.mouse.move(x, y, { steps: 8 });
    return page.evaluate(
      ([x, y, selector]) => {
        const hit = document.elementFromPoint(x as number, y as number);
        const target = [...document.querySelectorAll(selector as string)].at(-1);
        return {
          onTarget: !!hit && !!target && (target === hit || target.contains(hit)),
          hit: hit ? `${hit.tagName.toLowerCase()}.${[...hit.classList].join(".")}` : null,
        };
      },
      [x, y, selector] as const,
    );
  };
  // Base UI's tooltip popup (ui/Tooltip.tsx) or the title tooltip (ui/titleTooltips.ts), shown.
  const tooltipShows = () =>
    page.locator(".ui-tooltip[data-open]:visible, .ui-title-tooltip:visible").first().waitFor({ timeout: 5_000 });

  test("a time in a reply opens its exact-date tooltip", async () => {
    expect(await pointAt(".acpmux-scroll .cv-time-hover")).toMatchObject({ onTarget: true });
    await tooltipShows();
  });

  test("a link in a reply opens its preview card", async () => {
    expect(await pointAt('.acpmux-scroll a[href^="https://example.com/checks/"]')).toMatchObject({ onTarget: true });
    await page.locator(".cv-link-preview").first().waitFor({ state: "visible", timeout: 5_000 });
  });

  test("a prompt's time opens its exact-date tooltip", async () => {
    await pointAt(".acpmux-row:has(.cv-user__time)");
    expect(await pointAt(".cv-user__time")).toMatchObject({ onTarget: true });
    await tooltipShows();
  });

  test("a reply's actions show under the pointer, and Copy names itself", async () => {
    await pointAt(".acpmux-row:has(.cv-turn-actions)");
    expect(await pointAt(".cv-turn-actions .cv-iconbtn")).toMatchObject({ onTarget: true });
    const shown = await page.evaluate(() => {
      const group = [...document.querySelectorAll<HTMLElement>(".cv-turn-actions .cv-turn-action-group")].at(-1);
      return group ? Number(getComputedStyle(group).opacity) : -1;
    });
    expect(shown).toBeGreaterThan(0.9);
    await tooltipShows();
  });
}
