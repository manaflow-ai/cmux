// The header's top-right buttons stay put whatever shows at the top of the pane (Leo, 2026-11-23: "more often than
// not unwilling to accept a banner at the top of a single ... line that gets cut off and also inadvertently shifts the
// ... buttons on the top right down with it because they got ... glued in to the row. ... the ... buttons on the top
// right NEED to be done right, especially when things are at compressed width panes."). Two banners: the line under
// the header (WatchBanner here) and the connection warning that leads the tools in the pane's tab row
// (ChatHeaderInlineStatus). The warning is a row accessory: it neither folds a button into the "..." nor raises the
// tools' need, which is what the App's tab row weighs to keep the tools in the row or drop them to a line of their
// own (PaneTabRowSharing.fitsTabRow). With no room it hides whole and the "..." carries a warning dot.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser, type Page } from "playwright";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("chat-header-banner-tools-still.test.ts", async () => {
  setDefaultTimeout(180_000);
  let browser: Browser;
  let pane: Awaited<ReturnType<typeof papercutPane>>;
  let watched: Awaited<ReturnType<typeof papercutPane>>;

  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    pane = await papercutPane(() => browser, { turns: 2, running: false });
    watched = await papercutPane(() => browser, { turns: 2, running: false, session: { watching: "claude" } });
  });
  afterAll(async () => {
    await pane?.close();
    await watched?.close();
    await browser?.close();
  });

  type Recorder = { __tabRowNeed?: number[] };
  const record = (page: Page) =>
    page.evaluate(() => {
      const needs: number[] = [];
      (window as Recorder).__tabRowNeed = needs;
      window.cmuxAcpmuxActions!["pane.tabRowTools"] = async (params) => {
        needs.push((params as { need: number }).need);
        return null;
      };
    });
  const offer = (page: Page) =>
    page.evaluate(async () => {
      const url = "/header/tabRow.ts";
      const module = (await import(/* @vite-ignore */ url)) as { setTabRow(value: unknown): void };
      module.setTabRow({ height: 40, trailingInset: 12 });
    });

  /// Each header button's place, the "..."'s warning dot, and the need last reported to the App.
  const measure = (page: Page) =>
    page.evaluate(async () => {
      // After three painted frames: the tools report their need in a layout effect and the tab row
      // answers with the accessories' room, so the buttons sit where they rest.
      await new Promise<void>((done) => {
        let count = 0;
        window.cmuxAfterPaint(() => {
          if (++count < 3) return true;
          done();
          return false;
        });
      });
      const tools = document.querySelector<HTMLElement>(".acpmux-handoff-header-tools")!;
      const buttons = [...tools.querySelectorAll<HTMLElement>("button")].map((button) => {
        const box = button.getBoundingClientRect();
        return `${button.getAttribute("aria-label")}@${Math.round(box.x)},${Math.round(box.y)}`;
      });
      const more = tools.querySelector(".acpmux-header-more");
      const needs = (window as Recorder).__tabRowNeed ?? [];
      return {
        buttons,
        dot: more ? getComputedStyle(more, "::after").content !== "none" : false,
        need: needs.at(-1),
        status: tools.querySelector<HTMLElement>(".acpmux-status--inline")?.getBoundingClientRect().width ?? 0,
      };
    });

  /// Mounts the real ChatHeaderInlineStatus where the pane puts it, at the start of the tools.
  const warn = (page: Page, status: string) =>
    page.evaluate(async (status) => {
      // The page's own React: the URL Vite rewrote the label's JSX runtime to names its prebundled deps' folder and
      // version, so the label renders with the React the pane runs.
      const source = await (await fetch("/header/ChatHeaderStatus.tsx")).text();
      const runtime = source.match(/["']([^"']*\/deps\/react_jsx-(?:dev-)?runtime\.js[^"']*)["']/)?.[1];
      if (!runtime) throw new Error(`no prebundled JSX runtime in ChatHeaderStatus.tsx: ${source.slice(0, 400)}`);
      const dep = (name: string) => runtime.replace(/react_jsx-(?:dev-)?runtime/, name);
      // Prebundled CommonJS: the named exports sit on the default one.
      const [react, client, { ChatHeaderInlineStatus }] = await Promise.all([
        import(/* @vite-ignore */ dep("react")),
        import(/* @vite-ignore */ dep("react-dom_client")),
        import(/* @vite-ignore */ "/header/ChatHeaderStatus.tsx" as string),
      ]);
      const { createElement } = react.createElement ? react : react.default;
      const { createRoot } = client.createRoot ? client : client.default;
      const tools = document.querySelector<HTMLElement>(".acpmux-handoff-header-tools")!;
      const host = document.createElement("span");
      host.style.display = "contents";
      tools.prepend(host);
      createRoot(host).render(createElement(ChatHeaderInlineStatus, { status, detail: status }));
      while (!tools.querySelector(".acpmux-status--inline")) await new Promise((done) => requestAnimationFrame(done));
    }, status);

  for (const width of [280, 480, 900]) {
    test(`${width} px, tab row: the connection warning moves no button and leaves the row's need alone`, async () => {
      const page = await pane.open({ width, height: 500 });
      try {
        await record(page);
        await offer(page);
        await page.waitForFunction(() => ((window as Recorder).__tabRowNeed ?? []).length > 0);
        const before = await measure(page);
        await warn(page, "Disconnected: acpmux stopped answering on this machine a while ago");
        const after = await measure(page);
        expect(after.buttons).toEqual(before.buttons);
        expect(after.need).toBe(before.need);
        // Shown within the room the buttons leave, or hidden whole with the dot on the "...".
        if (after.status === 0) expect(after.dot).toBe(true);
        else {
          expect(after.status).toBeLessThanOrEqual(160);
          expect(after.dot).toBe(false);
        }
      } finally {
        await page.close();
      }
    });

    test(`${width} px: the line under the header moves no button`, async () => {
      const plain = await pane.open({ width, height: 500 });
      const banner = await watched.open({ width, height: 500 });
      try {
        await banner.getByRole("button", { name: "Take Over" }).waitFor();
        expect((await measure(banner)).buttons).toEqual((await measure(plain)).buttons);
      } finally {
        await plain.close();
        await banner.close();
      }
    });
  }
});
