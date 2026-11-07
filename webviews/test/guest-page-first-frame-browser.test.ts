// l10n-allow-file: browser fixture labels, not shipped UI.
// cmux-web-test-timeout: 300
// The guest page's first frame is its final layout (Leo, 2026-11-07: the composer "was the only
// thing that was seen for a while and then it got repositioned ... we should be able to expect that
// it goes on the bottom when it loads in the web app"). The page opens for a guest who already
// joined, the room holds its snapshot back, and the dock (the guest's messages and composer, or the
// view-only line) must sit at the bottom of the viewport on the frame that first shows it and stay
// at exactly that place once the transcript has drawn.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type WebSocketRoute } from "playwright";
import type { ViteDevServer } from "vite";
import { joinFrames, workingRecords } from "../src/agent-session/guest/fixtures/liveChat";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("guest-page-first-frame-browser.test.ts", async () => {
  const SHARE = "c2hhcmUtZmlyc3RmcmFtZQ";
  const VIEWPORT = { width: 390, height: 844 };
  setDefaultTimeout(240_000);
  let vite: ViteDevServer;
  let browser: Browser;
  let origin: string;

  beforeAll(async () => {
    const { createServer } = await import("vite");
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.guest-page.mjs"),
      // Served at the root, so both /g/<id> and /i/<id> fall back to the page.
      base: "/",
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, `/g/${SHARE}`);
    origin = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const [kind, route, via, role] of [
    ["a link guest (view only)", "g", "link", undefined],
    ["an invitee who may talk (composer)", "i", "invite", "talk"],
  ] as const) {
    test(`${kind}: the dock is at the bottom on its first frame and never moves`, async () => {
      const page = await browser.newPage({ viewport: VIEWPORT, deviceScaleFactor: 2 });
      const errors: string[] = [];
      page.on("pageerror", (error) => errors.push(error.message));
      await page.addInitScript(
        ({ share, via, role }) => {
          sessionStorage.setItem(`cmux.guest.${share}.joined`, "g1");
          sessionStorage.setItem(`cmux.guest.${share}.via`, via);
          if (role) sessionStorage.setItem(`cmux.guest.${share}.role`, role);
          const marks: { first?: DOMRect } = {};
          (window as unknown as { __dock: typeof marks }).__dock = marks;
          // The dock's place on the frame that first shows it (measured before that frame paints).
          new MutationObserver((_, observer) => {
            const dock = document.querySelector(".guest-live__dock");
            if (!dock) return;
            observer.disconnect();
            requestAnimationFrame(() => (marks.first = dock.getBoundingClientRect()));
          }).observe(document, { childList: true, subtree: true });
        },
        { share: SHARE, via, role },
      );
      let opened!: (room: WebSocketRoute) => void;
      const room = new Promise<WebSocketRoute>((resolve) => (opened = resolve));
      const [presence, snapshot] = joinFrames(workingRecords());
      // The room answers presence at once and holds the snapshot until the test sends it.
      await page.routeWebSocket(`**/v1/chat-shares/${SHARE}/guest`, (socket) => {
        socket.send(JSON.stringify(presence));
        opened(socket);
      });
      await page.goto(`${origin}/${route}/${SHARE}`);
      await page.waitForFunction(() => (window as unknown as { __dock: { first?: DOMRect } }).__dock.first);
      const first = await page.evaluate(() => {
        const rect = (window as unknown as { __dock: { first: DOMRect } }).__dock.first;
        return { top: rect.top, bottom: rect.bottom, height: rect.height };
      });
      // At the bottom of the viewport from the first frame, before the room has sent the chat.
      expect(first.bottom).toBeCloseTo(VIEWPORT.height, 0);
      expect(await page.locator(".guest-live__transcript [data-row-id]").count()).toBe(0);
      if (role === "talk") expect(await page.locator(".guest-live__dock textarea").count()).toBe(1);

      (await room).send(JSON.stringify(snapshot));
      await page.locator(".guest-live__transcript [data-row-id]").first().waitFor();
      // Two frames after the transcript drew: whatever it laid out has settled.
      await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
      const live = await page.locator(".guest-live__dock").boundingBox();
      expect(live).not.toBeNull();
      expect(live!.y).toBe(first.top);
      expect(live!.height).toBe(first.height);
      expect(errors).toEqual([]);
      await page.close();
    });
  }
});
