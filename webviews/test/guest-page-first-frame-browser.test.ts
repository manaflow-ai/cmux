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

  // A dropped connection fails the transcript chunk's request (#38101 F1). Since #51599 the page
  // asks nothing (no Retry: Leo, 2026-11-22, "vacuous decisions like that should be just done"): it
  // tries again on its own, reloads once when the browser keeps the failed import, says one quiet
  // line once the failure has lasted, and draws the chat as soon as the chunk loads. A reload keeps
  // the guest's unsent draft.
  test("a transcript chunk whose request fails: the page retries on its own and the chat draws", async () => {
    const page = await browser.newPage({ viewport: VIEWPORT, deviceScaleFactor: 2 });
    await page.addInitScript((share) => {
      sessionStorage.setItem(`cmux.guest.${share}.joined`, "g1");
      sessionStorage.setItem(`cmux.guest.${share}.via`, "invite");
      sessionStorage.setItem(`cmux.guest.${share}.role`, "talk");
    }, SHARE);
    let online = false;
    // The first failure waits until the draft is typed, so the page's own reload comes after it.
    let typed!: () => void;
    const draftTyped = new Promise<void>((resolve) => (typed = resolve));
    await page.route(/\/GuestTranscript\.tsx(\?|$)/, async (request) => {
      if (online) return request.continue();
      await draftTyped;
      await request.abort();
    });
    const frames = joinFrames(workingRecords());
    await page.routeWebSocket(`**/v1/chat-shares/${SHARE}/guest`, (socket) => {
      for (const frame of frames) socket.send(JSON.stringify(frame));
    });
    await page.goto(`${origin}/i/${SHARE}`);
    const draft = page.locator(".guest-live__dock textarea");
    // The composer works while the chat cannot load; what the guest types survives the reload.
    await draft.fill("Can you run it on the CI image too?");
    const reloaded = page.waitForEvent("load");
    typed();
    await reloaded;
    expect(await draft.inputValue()).toBe("Can you run it on the CI image too?");
    // Still offline after the one reload: the page keeps trying and, once that has lasted, says so
    // in one line with nothing to press.
    const notice = page.locator(".guest-live__transcript .guest-live__notice");
    await notice.waitFor({ timeout: 60_000 });
    expect(await page.locator(".guest-live__transcript button").count()).toBe(0);
    online = true;
    await page.locator(".guest-live__transcript [data-row-id]").first().waitFor({ timeout: 60_000 });
    expect(await notice.count()).toBe(0);
    expect(await page.locator(".guest-live__transcript [role=alert]").count()).toBe(0);
    expect(await draft.inputValue()).toBe("Can you run it on the CI image too?");
    await page.close();
  });

  // A reload with a message still held (#38197 F1): the dock draws the held bubble on the first frame,
  // before the transcript's stylesheet (the pane's sheet past the first frame's part) has arrived.
  // When it arrives, neither the bubble nor the dock changes size or place.
  test("a reload with a held message: the dock keeps its size when the transcript's sheet arrives", async () => {
    const page = await browser.newPage({ viewport: VIEWPORT, deviceScaleFactor: 2 });
    const errors: string[] = [];
    page.on("pageerror", (error) => errors.push(error.message));
    await page.addInitScript((share) => {
      sessionStorage.setItem(`cmux.guest.${share}.joined`, "g1");
      sessionStorage.setItem(`cmux.guest.${share}.via`, "invite");
      sessionStorage.setItem(`cmux.guest.${share}.role`, "talk");
      sessionStorage.setItem(
        `cmux.guest.${share}.prompts`,
        JSON.stringify([
          { clientId: "c1", text: "Could you also run the upload tests on Linux?", at: 1, state: "held" },
        ]),
      );
    }, SHARE);
    // The transcript's chunk and its sheet wait until the first frame is measured: the built page loads
    // them together, and on the dev server the chunk's own modules bring in sheets of their own.
    let releaseSheet!: () => void;
    const sheetHeld = new Promise<void>((resolve) => (releaseSheet = resolve));
    let held = 0;
    await page.route(/\/(GuestTranscript\.tsx|transcriptSheet\.ts|transcript\.virtual\.css)(\?|$)/, async (request) => {
      held += 1;
      await sheetHeld;
      await request.continue();
    });
    const frames = joinFrames(workingRecords());
    await page.routeWebSocket(`**/v1/chat-shares/${SHARE}/guest`, (socket) => {
      for (const frame of frames) socket.send(JSON.stringify(frame));
    });
    await page.goto(`${origin}/i/${SHARE}`);
    const bubble = page.locator(".guest-mine .cv-user__bubble");
    await bubble.waitFor();
    const before = { dock: await page.locator(".guest-live__dock").boundingBox(), bubble: await bubble.boundingBox() };
    expect(await page.locator(".guest-live__transcript [data-row-id]").count()).toBe(0);
    expect(held).toBeGreaterThan(0);
    releaseSheet();
    await page.locator(".guest-live__transcript [data-row-id]").first().waitFor();
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    const after = { dock: await page.locator(".guest-live__dock").boundingBox(), bubble: await bubble.boundingBox() };
    expect(after).toEqual(before);
    expect(before.dock!.y + before.dock!.height).toBeCloseTo(VIEWPORT.height, 0);
    expect(errors).toEqual([]);
    await page.close();
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
          const marks: { first?: DOMRect; area?: DOMRect; bubbleRadius?: string } = {};
          (window as unknown as { __dock: typeof marks }).__dock = marks;
          // The dock's place on the frame that first shows it (measured before that frame paints).
          new MutationObserver((_, observer) => {
            const dock = document.querySelector(".guest-live__dock");
            if (!dock) return;
            observer.disconnect();
            // raf-read: the layout the first frame with the dock paints, before any later commit moves it.
            requestAnimationFrame(() => {
              marks.area = document.querySelector(".guest-live__transcript")!.getBoundingClientRect();
              marks.first = dock.getBoundingClientRect();
            });
          }).observe(document, { childList: true, subtree: true });
          // The transcript's stylesheet loads apart from the first frame's (vite.config.guest-page.mjs):
          // the first prompt bubble is styled by it as it is put in the page, so no row draws unstyled.
          new MutationObserver((_, observer) => {
            const bubble = document.querySelector(".guest-live__transcript .cv-user__bubble");
            if (!bubble) return;
            observer.disconnect();
            marks.bubbleRadius = getComputedStyle(bubble).borderTopLeftRadius;
          }).observe(document, { childList: true, subtree: true });
        },
        { share: SHARE, via, role },
      );
      let opened!: (room: WebSocketRoute) => void;
      const room = new Promise<WebSocketRoute>((resolve) => (opened = resolve));
      const [presence, snapshot] = joinFrames(workingRecords()) as [
        { participants: { name: string; kind?: string }[] },
        object,
      ];
      // The longest owner name a room sends (64 characters): "Shared by …" stays one line.
      const owner = "Maximiliana Anastasia Featherstonehaugh-Cholmondeley Worthington";
      const named = {
        ...presence,
        participants: presence.participants.map((one) => (one.kind === "owner" ? { ...one, name: owner } : one)),
      };
      // The room holds presence and the snapshot until the test sends them.
      await page.routeWebSocket(`**/v1/chat-shares/${SHARE}/guest`, (socket) => opened(socket));
      await page.goto(`${origin}/${route}/${SHARE}`);
      await page.waitForFunction(() => (window as unknown as { __dock: { first?: DOMRect } }).__dock.first);
      const first = await page.evaluate(() => {
        const { first: rect, area } = (window as unknown as { __dock: { first: DOMRect; area: DOMRect } }).__dock;
        return { top: rect.top, bottom: rect.bottom, height: rect.height, areaTop: area.top };
      });
      // At the bottom of the viewport from the first frame, before the room has sent the chat.
      expect(first.bottom).toBeCloseTo(VIEWPORT.height, 0);
      expect(await page.locator(".guest-live__transcript [data-row-id]").count()).toBe(0);
      if (role === "talk") expect(await page.locator(".guest-live__dock textarea").count()).toBe(1);

      const socket = await room;
      socket.send(JSON.stringify(named));
      socket.send(JSON.stringify(snapshot));
      await page.locator(".guest-live__transcript [data-row-id]").first().waitFor();
      // Two frames after the transcript drew: whatever it laid out has settled.
      await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
      const live = await page.locator(".guest-live__dock").boundingBox();
      expect(live).not.toBeNull();
      expect(live!.y).toBe(first.top);
      expect(live!.height).toBe(first.height);
      // The header kept its height: the transcript's area starts where it did on the first frame.
      expect((await page.locator(".guest-live__transcript").boundingBox())!.y).toBe(first.areaTop);
      // The prompt's bubble had its rounded corners the moment it was put in the page.
      const bubbleRadius = await page.evaluate(
        () => (window as unknown as { __dock: { bubbleRadius?: string } }).__dock.bubbleRadius,
      );
      expect(bubbleRadius).toBeDefined();
      expect(bubbleRadius).not.toBe("0px");
      expect(errors).toEqual([]);
      await page.close();
    });
  }
});
