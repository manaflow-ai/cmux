// cmux-web-test-timeout: 600
// The check of "A connect is one inline card, one tap" (cmuxterm-hq docs/design/remote-integrations.md;
// leo-workspace design/chat-transcript.md "Connect flows"). Leo, 2026-11-10: "make that sequence of
// steps far more ergonomic, if not like nigh automatic. Just as few hurdles to jump through as
// possible." It walks the chat's Connect GitHub card at phone width (390x844) and desktop width, from
// a chat whose GitHub call found no connection, and counts every tap and screen the person meets:
//   fresh: Connect GitHub (1) -> GitHub's install page for the repository's owner: Install (2) ->
//          GitHub's return opens the chat -> the chat's Continue goes by itself;
//   reuse: Connect GitHub (1) -> GitHub's authorize page passes straight back -> Continue goes.
// It fails when either count goes up. With FAST_CHECKS_OUT (cmux-ci test --artifact) it writes the
// counts and a still of every gallery state at both widths there, for the PR.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

await requireBrowserLane("github-connect-taps-browser.test.ts", async () => {
  const ENTRY = "agent-pane.github-connect-card";
  const WIDTHS = [
    { name: "phone", width: 390, height: 844 },
    { name: "desktop", width: 1280, height: 800 },
  ] as const;
  const STATES = [
    "not-connected",
    "not-connected-no-repo",
    "needs-reauth",
    "not-covered",
    "waiting",
    "continuing",
    "refused",
    "read-only",
  ] as const;
  /// The most each walk may take: the rule's budget (one tap in the chat, one on GitHub's own page
  /// when GitHub has to ask).
  const BUDGET = { fresh: { taps: 2, screens: 2 }, reuse: { taps: 1, screens: 1 } } as const;
  /// Before this card (design 3.1, counted from the code at f761a64, fresh account, a Cloud chat whose
  /// push fails): Settings, Accounts, GitHub Connect, account, repositories, Install, switch back, "try again".
  const BEFORE = { taps: 8, screens: 5 } as const;

  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const out = process.env.FAST_CHECKS_OUT ? path.join(process.env.FAST_CHECKS_OUT, "github-connect") : undefined;
  const counts: Record<string, unknown> = { before: BEFORE };

  beforeAll(async () => {
    const root = path.resolve(import.meta.dir, "..");
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "walk-fresh" } });
    if (out) mkdirSync(out, { recursive: true });
  }, 240_000);
  afterAll(async () => {
    if (out) writeFileSync(path.join(out, "taps.json"), `${JSON.stringify(counts, null, 2)}\n`);
    await browser?.close();
    await vite?.close();
  });

  async function open(variant: string, width: number, height: number): Promise<Page> {
    const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 2 });
    const { port } = vite.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width, height })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.locator("[data-github-connect]").waitFor();
    return page;
  }

  /// The person leaves the chat for GitHub's page and GitHub's return brings the chat back: the page
  /// goes hidden, then visible, as the app's window does when the browser comes in front and leaves.
  async function awayAndBack(page: Page) {
    await page.evaluate(() => {
      const set = (state: DocumentVisibilityState) => {
        Object.defineProperty(document, "visibilityState", { configurable: true, get: () => state });
        document.dispatchEvent(new Event("visibilitychange"));
      };
      set("hidden");
      set("visible");
    });
  }

  const walk = (page: Page) =>
    page.evaluate(
      () =>
        (globalThis as { __githubConnectWalk?: unknown }).__githubConnectWalk ?? { asked: [], opened: [], sent: [] },
    ) as Promise<{
      asked: (string | null)[];
      opened: string[];
      sent: string[];
    }>;

  for (const { name, width, height } of WIDTHS) {
    test(`${name}: a fresh account connects in two taps and the chat goes on by itself`, async () => {
      const chat = await open("walk-fresh", width, height);
      let taps = 0;
      const screens = new Set<string>(["chat"]);
      try {
        // Tap 1, in the chat: the card's one button.
        expect(await chat.locator("[data-github-connect] button").allTextContents()).toEqual(["Connect GitHub"]);
        await chat.getByRole("button", { name: "Connect GitHub" }).click();
        taps += 1;
        await chat.locator('[data-github-connect="waiting"]').waitFor();
        const { asked, opened } = await walk(chat);
        expect(asked).toEqual(["acme/web"]);
        expect(opened).toEqual(["https://github.com/apps/cmux/installations/new/permissions"]);
        // GitHub's own install page for the repository's owner (preselected by target_id): Install.
        const github = await browser.newPage({ viewport: { width, height } });
        screens.add("github-install");
        await github.setContent(
          '<main><h1>Install cmux</h1><p>on acme</p><button id="install">Install</button></main>',
        );
        await github.click("#install");
        taps += 1;
        await github.close();
        // GitHub's return (the dashboard's callback opens the chat's link): back in the chat.
        await awayAndBack(chat);
        await chat.locator('[data-github-connect="continuing"]').waitFor();
        expect((await walk(chat)).sent).toEqual(["Continue"]);
        counts[`${name}.fresh`] = { taps, screens: screens.size };
        expect(taps).toBeLessThanOrEqual(BUDGET.fresh.taps);
        expect(screens.size).toBeLessThanOrEqual(BUDGET.fresh.screens);
      } finally {
        await chat.close();
      }
    });

    test(`${name}: an installation that covers the repository connects in one tap`, async () => {
      const chat = await open("walk-reuse", width, height);
      let taps = 0;
      try {
        await chat.getByRole("button", { name: "Connect GitHub" }).click();
        taps += 1;
        await chat.locator('[data-github-connect="waiting"]').waitFor();
        expect((await walk(chat)).opened).toEqual(["https://github.com/login/oauth/authorize"]);
        // GitHub skips its page for an app the person already authorized: no tap there.
        await awayAndBack(chat);
        await chat.locator('[data-github-connect="continuing"]').waitFor();
        expect((await walk(chat)).sent).toEqual(["Continue"]);
        counts[`${name}.reuse`] = { taps, screens: 1 };
        expect(taps).toBeLessThanOrEqual(BUDGET.reuse.taps);
      } finally {
        await chat.close();
      }
    });

    test(`${name}: a refused Connect says why with the button that tries again`, async () => {
      const chat = await open("walk-refuse", width, height);
      try {
        await chat.getByRole("button", { name: "Connect GitHub" }).click();
        await chat.locator('[data-github-connect="refused"]').waitFor();
        expect(await chat.locator("[data-github-connect]").textContent()).toContain(
          "Sign in to cmux to connect GitHub.",
        );
        expect(await chat.locator("[data-github-connect] button").allTextContents()).toEqual(["Try again"]);
        expect((await walk(chat)).sent).toEqual([]);
      } finally {
        await chat.close();
      }
    });

    test(`${name}: every state fits the width, one line and at most one button`, async () => {
      for (const state of STATES) {
        const page = await open(state, width, height);
        try {
          const card = page.locator("[data-github-connect]");
          const box = await card.boundingBox();
          expect(box).not.toBeNull();
          expect(box!.x + box!.width).toBeLessThanOrEqual(width);
          expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
          expect((await card.locator("button").count()) <= 1).toBe(true);
          // The chat's column down to the footer row under the card.
          const clip = { x: 0, y: 0, width, height: Math.min(height, Math.ceil(box!.y + box!.height + 64)) };
          if (out) await page.screenshot({ path: path.join(out, `${name}-${state}.png`), clip });
        } finally {
          await page.close();
        }
      }
    });
  }
});
