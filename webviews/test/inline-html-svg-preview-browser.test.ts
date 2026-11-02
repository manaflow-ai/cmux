// The inline preview frame's isolation in a real browser (InlinePreview.tsx, previewDocument.ts): a
// document in a frame sandboxed with `allow-scripts` and no same-origin, behind the preview policy.
// Its own scripts never run (only the nonce'd frame script does). Even with inline scripts allowed,
// under the sandbox alone, a script cannot read `parent.document`, and `fetch` is refused by the
// policy without a request leaving the page. The height report reaches the parent; the frame refuses
// a link out and has no live refresh.
//
// Real Chromium and WebKit from Playwright; CI fails the file when they cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser } from "playwright";
import {
  inlinePreviewDocument,
  INLINE_PREVIEW_SANDBOX,
} from "../src/agent-session/acpmux/conversation/previewDocument";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Message = { type?: string; result?: Record<string, unknown>; height?: number };

await requireBrowserLane("inline-html-svg-preview-browser.test.ts", async () => {
  setDefaultTimeout(60_000);
  const PROBE = "https://inline-preview-probe.invalid/";
  // A document whose script reports what it could do, through the one channel the frame has: first
  // that it ran at all (posted while the document parses, so before the height report), then the
  // result once fetch settles.
  const probe = `<h1>probe</h1><script>
parent.postMessage({ type: "probe-ran" }, "*");
(async () => {
  const result = { ran: true };
  try { result.parentTitle = parent.document.title; result.parentReadable = true; }
  catch (error) { result.parentReadable = false; }
  try { await fetch("${PROBE}fetch"); result.fetched = true; }
  catch { result.fetched = false; }
  parent.postMessage({ type: "probe", result }, "*");
})();
</script><img src="${PROBE}image">`;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    browsers.set("chromium", await chromium.launch({ headless: true }));
    browsers.set("webkit", await webkit.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
  });

  /// Loads `srcdoc` in a sandboxed frame of a parent page and collects the frame's messages until one
  /// of type `until` arrives; also every request to the probe host.
  async function load(engine: string, srcdoc: string, until: string) {
    const page = await browsers.get(engine)!.newPage();
    const requests: string[] = [];
    await page.route(`${PROBE}**`, (route) => {
      requests.push(route.request().url());
      return route.abort();
    });
    await page.setContent("<title>parent secret</title><body></body>");
    const messages = await page.evaluate(
      ({ srcdoc, sandbox, until }) =>
        new Promise<unknown[]>((resolve) => {
          const got: { type?: string }[] = [];
          const frame = document.createElement("iframe");
          addEventListener("message", (event) => {
            if (event.source !== frame.contentWindow) return;
            got.push(event.data);
            if (event.data?.type === until) resolve(got);
          });
          frame.setAttribute("sandbox", sandbox);
          frame.srcdoc = srcdoc;
          document.body.append(frame);
        }),
      { srcdoc, sandbox: INLINE_PREVIEW_SANDBOX, until },
    );
    await page.close();
    return { messages: messages as Message[], requests };
  }

  /// A passive document with a link and a refresh, in a sandboxed frame; resolves with the frame once
  /// its height has reported (the frame's own script has run).
  async function passiveFrame(engine: string) {
    const page = await browsers.get(engine)!.newPage();
    const requests: string[] = [];
    await page.route(`${PROBE}**`, (route) => {
      requests.push(route.request().url());
      return route.abort();
    });
    await page.setContent("<body></body>");
    const srcdoc = inlinePreviewDocument(
      "html",
      `<meta http-equiv="refresh" content="0;url=${PROBE}refresh"><a id="out" href="${PROBE}link">out</a><a id="in" href="#in">in</a>`,
      "",
      "0123456789abcdef0123456789abcdef",
    );
    await page.evaluate(
      ({ srcdoc, sandbox }) =>
        new Promise<void>((resolve) => {
          const frame = document.createElement("iframe");
          addEventListener("message", (event) => {
            if (event.source === frame.contentWindow && event.data?.type === "cmux-preview-size") resolve();
          });
          frame.setAttribute("sandbox", sandbox);
          frame.srcdoc = srcdoc;
          document.body.append(frame);
        }),
      { srcdoc, sandbox: INLINE_PREVIEW_SANDBOX },
    );
    const frame = await (await page.$("iframe"))!.contentFrame();
    return { page, frame: frame!, requests };
  }

  for (const engine of ["chromium", "webkit"]) {
    test(`${engine}: a passive frame stays on its document: no refresh, no link out, fragments scroll in place`, async () => {
      const { page, frame, requests } = await passiveFrame(engine);
      const result = await frame.evaluate(() => {
        const click = (id: string) => {
          const event = new MouseEvent("click", { bubbles: true, cancelable: true });
          document.getElementById(id)!.dispatchEvent(event);
          return event.defaultPrevented;
        };
        return {
          refreshes: document.querySelectorAll("meta[http-equiv=refresh i]").length,
          outHref: document.getElementById("out")!.getAttribute("href"),
          outPrevented: click("out"),
          inPrevented: click("in"),
        };
      });
      // The link out points nowhere (previewDocument.ts inertDocument), and every click is handled in
      // the frame: a fragment scrolls there (in srcdoc `#x` resolves against the parent page).
      expect(result).toEqual({ refreshes: 0, outHref: "#", outPrevented: true, inPrevented: true });
      expect(await frame.evaluate(() => document.getElementById("in") !== null)).toBe(true);
      expect(requests).toEqual([]);
      await page.close();
    });

    test(`${engine}: the document's script never runs, and the height still reports`, async () => {
      const { messages, requests } = await load(
        engine,
        inlinePreviewDocument("html", probe, "", "0123456789abcdef0123456789abcdef"),
        "cmux-preview-size",
      );
      expect(messages.some((message) => message.type?.startsWith("probe"))).toBe(false);
      expect(messages.at(-1)?.height).toBeGreaterThan(0);
      // The image is refused by the policy before any request leaves.
      expect(requests).toEqual([]);
    });

    test(`${engine}: with scripts allowed, a script still cannot read parent.document and fetch is refused`, async () => {
      const { messages, requests } = await load(engine, inlinePreviewDocument("html", probe, "", undefined), "probe");
      const result = messages.find((message) => message.type === "probe")?.result;
      expect(result?.ran).toBe(true);
      expect(result?.parentReadable).toBe(false);
      expect(result?.parentTitle).toBeUndefined();
      expect(result?.fetched).toBe(false);
      expect(requests).toEqual([]);
    });
  }
});
