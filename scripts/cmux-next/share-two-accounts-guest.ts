// Browser half of the staging sharing flow. All timestamps use the job process's monotonic clock.
import { rename } from "node:fs/promises";
import { createRequire } from "node:module";
import { join } from "node:path";
import type { Browser, BrowserContext, Video } from "../gallery-matrix/node_modules/playwright";

const PAGE_ORIGIN = "https://share-staging.cmux.dev";
const ROOM_ORIGIN = "https://cmux-platform-staging.debussy.workers.dev";
const WAIT_MS = 15_000;

// Playwright errors can include request headers and navigation URLs (the share secret is in the
// fragment). Only the operation and an explicitly chosen HTTP status may leave this file.
async function step<T>(name: string, fn: () => Promise<T>, ms = WAIT_MS): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      fn(),
      new Promise<never>((_, reject) => { timer = setTimeout(reject, ms); }),
    ]);
  } catch {
    throw new Error(`Guest ${name} failed or timed out (${ms} ms)`);
  } finally {
    clearTimeout(timer);
  }
}

export function stagingLink(raw: string): URL {
  let link: URL;
  try { link = new URL(raw); } catch { throw new Error("Owner returned an invalid share URL"); }
  if (![PAGE_ORIGIN, ROOM_ORIGIN].includes(link.origin) || link.username || link.password
      || !/^\/g\/[A-Za-z0-9_-]{8,128}\/?$/.test(link.pathname) || !/^#[A-Za-z0-9_-]{8,128}$/.test(link.hash)) {
    throw new Error("Owner did not return a staging chat share link with its secret");
  }
  // Old room URLs redirect to the short host. Exchange the handoff on the host that owns the cookie.
  const short = new URL(link.pathname.replace(/\/$/, ""), PAGE_ORIGIN);
  short.hash = link.hash;
  return short;
}

export async function createGuest(out: string, guestAccess: string, shareURL: string) {
  const link = stagingLink(shareURL);
  const shareId = link.pathname.split("/")[2];
  const endpoint = new URL(`/v1/chat-shares/${shareId}/handoff`, PAGE_ORIGIN);
  const minted = await step("account handoff request", () => fetch(endpoint, {
    method: "POST", redirect: "error", signal: AbortSignal.timeout(WAIT_MS),
    headers: { authorization: `Bearer ${guestAccess}`, "content-type": "application/json" },
    body: JSON.stringify({ page: "g" }),
  }));
  if (minted.status !== 200) throw new Error(`Guest account handoff returned HTTP ${minted.status}`);
  const { handoff } = await step("account handoff response", () => minted.json());
  if (typeof handoff !== "string" || !/^[\w-]{43}$/.test(handoff)) throw new Error("Guest account handoff returned no code");

  const { chromium } = createRequire(new URL("../gallery-matrix/package.json", import.meta.url))("playwright") as
    typeof import("../gallery-matrix/node_modules/playwright");
  const browser: Browser = await step("Chromium launch", async () => {
    try { return await chromium.launch({ timeout: WAIT_MS }); }
    catch { return chromium.launch({ channel: "chrome", timeout: WAIT_MS }); }
  }, WAIT_MS * 2 + 1000);
  let context: BrowserContext | undefined;
  let video: Video | null = null;
  let closed = false;
  async function close() {
    if (closed) return;
    closed = true;
    try {
      if (context) await step("browser context close", () => context!.close());
      if (video) {
        const recorded = await step("locate guest video", () => video!.path());
        await rename(recorded, join(out, "flow.webm"));
      }
    } finally {
      await step("browser shutdown", () => browser.close());
    }
  }
  try {
    const viewport = { width: 1280, height: 800 };
    const guest = await step("isolated browser context", () => browser.newContext({
      viewport, locale: "en-US", recordVideo: { dir: out, size: viewport },
    }));
    context = guest;
    guest.setDefaultTimeout(WAIT_MS);
    guest.setDefaultNavigationTimeout(WAIT_MS);
    // BrowserContext.request shares cookies with this context only. The one-use code is exchanged
    // before recording a page, so no URL or form with an account credential enters the video.
    const handoffURL = new URL(link.pathname, PAGE_ORIGIN);
    handoffURL.searchParams.set("cmux_handoff", handoff);
    const signed = await step("sign-in cookie exchange", () => guest.request.get(handoffURL.href, { maxRedirects: 0 }));
    if (signed.status() !== 302 && signed.status() !== 303) {
      throw new Error(`Guest sign-in cookie exchange returned HTTP ${signed.status()}`);
    }
    // Display names (including a fallback email), faces and owner labels are unnecessary in the
    // recording. Install before rendering the first frame, including the signed-in join button.
    await step("capture privacy styling", () => guest.addInitScript(() => {
      const sheet = new CSSStyleSheet();
      sheet.replaceSync(`
        .guest-join__as-label, .cv-author, .cv-presence, .cv-face, .guest-live__owner,
        .guest-mine__label, .guest-live__ask, .cv-typing { visibility: hidden !important; }
        .guest-join__as::after { content: "Join as guest"; }
      `);
      document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
    }));
    const page = await step("recorded page", () => guest.newPage());
    video = page.video();
    if (!video) throw new Error("Guest video recorder unavailable");
    const screenshot = (id: string) => step(`${id} screenshot`, () => page.screenshot({ path: join(out, `${id}.png`) }));
    // This run stays in the guest webview. Suppress the page's automatic native-protocol handoff.
    link.searchParams.set("in_app", "1");
    await step("open share link", () => page.goto(link.href, { waitUntil: "domcontentloaded" }));
    const joinButton = page.locator('[data-testid="guest-join-as"] button[type="submit"]');
    await step("signed-in Join button", () => joinButton.waitFor({ state: "visible" }));
    await screenshot("guest-join");
    const [redeemed] = await step("join by link", () => Promise.all([
      page.waitForResponse(r => r.url() === `${PAGE_ORIGIN}/v1/chat-shares/${shareId}/redeem` && r.request().method() === "POST"),
      joinButton.click(),
    ]));
    if (!redeemed.ok()) throw new Error(`Guest link redemption returned HTTP ${redeemed.status()}`);
    const grant = await step("read link role", () => redeemed.json());
    if (grant.role !== "talk") throw new Error("Guest link did not grant Talk rights");
    const field = page.locator(".guest-composer__field");
    await step("Talk composer", () => field.waitFor({ state: "visible" }));
    await step("initial transcript", () => page.locator('.guest-live__transcript[aria-busy="false"]').waitFor());
    await screenshot("guest-joined");

    let sample = 0;
    return {
      async waitUpdate(marker: string) {
        // One animation frame per check avoids Playwright's adaptive locator retry delay in this metric.
        await step("render owner update", () => page.waitForFunction(
          text => document.querySelector<HTMLElement>(".guest-live__transcript")?.innerText.includes(text),
          marker, { polling: "raf", timeout: WAIT_MS },
        ));
        const observed = performance.now();
        await screenshot(`guest-update-${String(++sample).padStart(2, "0")}`);
        return observed;
      },
      async send(marker: string) {
        await step("type Talk message", () => field.fill(marker));
        await screenshot("guest-typed");
        const sent = performance.now();
        await step("submit Talk message", () => page.locator('.guest-composer button[type="submit"]').click());
        return sent;
      },
      async waitCutoff() {
        await step("show owner-ended page", () => page.waitForFunction(
          () => document.querySelector<HTMLElement>('[data-testid="guest-ended"] h1')?.innerText === "The owner ended sharing",
          undefined, { polling: "raf", timeout: WAIT_MS },
        ));
        const observed = performance.now();
        await screenshot("guest-revoked");
        return observed;
      },
      close,
    };
  } catch (error) {
    await close();
    throw error;
  }
}
