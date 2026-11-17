// Temporary probe: which DevTools call hides a page to headless Chromium (document hidden, no frames).
import { chromium } from "./browsers";

// PROBE_CHANNEL=chrome: the installed Google Chrome in its new headless mode (real tabs and windows).
const server = await chromium.launchServer({
  headless: true,
  args: ["--process-per-site", "--js-flags=--expose-gc"],
  ...(process.env.PROBE_CHANNEL ? { channel: process.env.PROBE_CHANNEL } : {}),
});
const browser = await chromium.connect(server.wsEndpoint());
const context = await browser.newContext({ viewport: { width: 1200, height: 800 } });
const html = `<html><body>probe<script>
window.__log = [];
document.addEventListener("visibilitychange", () => __log.push(document.visibilityState + "@" + Math.round(performance.now())));
document.addEventListener("freeze", () => __log.push("freeze@" + Math.round(performance.now())));
document.addEventListener("resume", () => __log.push("resume@" + Math.round(performance.now())));
window.__raf = 0; const tick = () => { __raf++; requestAnimationFrame(tick); }; requestAnimationFrame(tick);
</script></body></html>`;
const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));
const state = async (page: import("playwright").Page, label: string) => {
  const a = await page.evaluate(() => (globalThis as unknown as { __raf: number }).__raf);
  await wait(1000);
  const s = await page.evaluate(() => ({
    vis: document.visibilityState,
    raf: (globalThis as unknown as { __raf: number }).__raf,
    log: (globalThis as unknown as { __log: string[] }).__log,
  }));
  console.log(`${label}: vis=${s.vis} raf/s=${s.raf - a} log=${s.log.join(",")}`);
};
const open = async () => {
  const page = await context.newPage();
  await page.goto(`data:text/html,${encodeURIComponent(html)}`);
  return { page, cdp: await context.newCDPSession(page) };
};
const keep = await open(); // a shown page, so the probes are not the only one
{
  const { page, cdp } = await open();
  await state(page, "baseline");
  await cdp.send("Page.setWebLifecycleState", { state: "frozen" });
  await cdp.send("Page.setWebLifecycleState", { state: "active" });
  await state(page, "frozen->active (immediate)");
  await wait(2000);
  await state(page, "frozen->active (+2s)");
}
{
  const { page, cdp } = await open();
  await cdp.send("Page.setWebLifecycleState", { state: "frozen" });
  await wait(2000);
  await cdp.send("Page.setWebLifecycleState", { state: "active" });
  await state(page, "frozen 2s then active");
}
{
  const { page, cdp } = await open();
  try {
    const { windowId } = (await cdp.send("Browser.getWindowForTarget" as never)) as { windowId: number };
    await cdp.send("Browser.setWindowBounds" as never, { windowId, bounds: { windowState: "minimized" } } as never);
    await state(page, "window minimized");
  } catch (e) {
    console.log(`window minimized: ${String(e).slice(0, 200)}`);
  }
}
{
  const { page, cdp } = await open();
  try {
    await cdp.send("Emulation.setFocusEmulationEnabled", { enabled: false });
    await keep.page.bringToFront();
    await state(page, "other page brought to front");
  } catch (e) {
    console.log(`bringToFront: ${String(e).slice(0, 200)}`);
  }
}
{
  const bcdp = await browser.newBrowserCDPSession();
  try {
    const { targetId } = (await bcdp.send("Target.createTarget", {
      url: "about:blank",
      background: true,
    } as never)) as {
      targetId: string;
    };
    console.log(`createTarget background: ${targetId}`);
    await wait(500);
    const page = context.pages().at(-1)!;
    await page.goto(`data:text/html,${encodeURIComponent(html)}`);
    await state(page, "createTarget background (last page)");
  } catch (e) {
    console.log(`createTarget background: ${String(e).slice(0, 200)}`);
  }
}
{
  const { page, cdp } = await open();
  try {
    // Hidden as a captured page would not be: the browser-side visibility through the screencast-off path.
    await cdp.send("Page.startScreencast" as never, { maxWidth: 1, maxHeight: 1, everyNthFrame: 1000 } as never);
    await cdp.send("Page.stopScreencast" as never);
    await cdp.send("Page.setWebLifecycleState", { state: "frozen" });
    await cdp.send("Page.setWebLifecycleState", { state: "active" });
    await state(page, "screencast on/off then frozen->active");
  } catch (e) {
    console.log(`screencast: ${String(e).slice(0, 200)}`);
  }
}
{
  // Tabs of one window: a tab opened in the background, then the foreground one switched.
  const bcdp = await browser.newBrowserCDPSession();
  try {
    const front = context.pages().at(-1)!;
    const frontCdp = await context.newCDPSession(front);
    const { targetInfo } = (await frontCdp.send("Target.getTargetInfo" as never)) as {
      targetInfo: { browserContextId: string };
    };
    const opened = context.waitForEvent("page");
    await bcdp.send("Target.createTarget", {
      url: `data:text/html,${encodeURIComponent(html)}`,
      newWindow: false,
      background: true,
      browserContextId: targetInfo.browserContextId,
    } as never);
    const tab = await opened;
    await tab.waitForLoadState();
    await state(tab, "background tab (createTarget newWindow false)");
    await tab.bringToFront();
    await state(tab, "background tab brought to front");
    await front.bringToFront();
    await state(tab, "front switched back to the other tab");
  } catch (e) {
    console.log(`tabs: ${String(e).slice(0, 300)}`);
  }
}
console.log(`browser version: ${browser.version()}`);
await browser.close();
await server.close();
