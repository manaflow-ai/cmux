// Popovers and menus open in one frame and fade only as they close (Leo 2026-10-24: "When you open
// it up, no animation. When you close it, animation for closing... No fade in ever for any of
// these."), on the real agent pane: the chat header's vertical ellipsis (a Base UI Menu,
// header/ChatHeaderTools.tsx ChatMenu) draws at full opacity, unscaled, with nothing running on it,
// in the frame it mounts and the next, and fades out on Escape. popover-instant-open.test.ts holds
// every stylesheet to the same rule. The page is the pane's dev entry talking to a stand-in acpmux
// (support/papercutChat.ts). Chromium; locally:
// CMUX_BROWSER_TESTS=1 bun test test/popover-instant-open-pane.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser } from "playwright";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("popover-instant-open-pane.test.ts", async () => {
  setDefaultTimeout(300_000);
  let browser: Browser;
  try {
    browser = await chromium.launch({ headless: true });
  } catch {
    console.warn("popover-instant-open: skipping (run `bunx playwright install chromium`)");
    describe.skip("popover instant open", () => test("chromium", () => {}));
    return;
  }
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    pane = await papercutPane(() => browser, { turns: 2, running: false });
    // The first load can run Vite's dependency optimizer and reload mid-compile.
    await (await pane.open()).close();
  });
  afterAll(async () => {
    await browser?.close();
    await pane?.close();
  });

  for (const reducedMotion of ["no-preference", "reduce"] as const)
    test(`the header's ... menu opens at full opacity with nothing running, and fades out (${reducedMotion})`, async () => {
      const page = await pane!.open();
      try {
        await page.emulateMedia({ reducedMotion });
        // What the menu draws in the frame it mounts and the next one, and every animation or
        // opacity transition that starts on it.
        await page.evaluate(() => {
          const probe = { mounted: [] as string[], started: [] as string[] };
          (window as unknown as { probe: typeof probe }).probe = probe;
          const motion = (popup: Element) =>
            popup
              .getAnimations({ subtree: true })
              .filter((animation) => Number(animation.effect?.getComputedTiming().activeDuration ?? 0) >= 1)
              .map((animation) => (animation as CSSAnimation).animationName ?? "transition");
          const read = (popup: Element) => {
            const style = getComputedStyle(popup);
            return `opacity ${style.opacity} transform ${style.transform} running [${motion(popup).join(",")}]`;
          };
          new MutationObserver(() => {
            const popup = document.querySelector(".acpmux-chat-menu-popover");
            if (!popup || probe.mounted.length) return;
            probe.mounted.push(read(popup));
            // raf-read: the frame after it mounts, where an open animation is still running.
            requestAnimationFrame(() => probe.mounted.push(read(popup)));
          }).observe(document.body, { childList: true, subtree: true });
          const record = (event: Event) => {
            if (!(event.target as Element).closest?.(".ui-popup")) return;
            if (event instanceof TransitionEvent && event.propertyName !== "opacity") return;
            probe.started.push(event instanceof AnimationEvent ? event.animationName : "opacity transition");
          };
          document.addEventListener("animationstart", record, true);
          document.addEventListener("transitionrun", record, true);
        });
        const probe = () =>
          page.evaluate(() => (window as unknown as { probe: { mounted: string[]; started: string[] } }).probe);
        await page.getByRole("button", { name: "Chat actions" }).click();
        const menu = page.locator(".acpmux-chat-menu-popover");
        await menu.waitFor();
        await page.waitForFunction(
          () => (window as unknown as { probe: { mounted: string[] } }).probe.mounted.length === 2,
        );
        const opened = await probe();
        expect(opened.mounted).toEqual(["opacity 1 transform none running []", "opacity 1 transform none running []"]);
        expect(opened.started).toEqual([]);
        await page.keyboard.press("Escape");
        await menu.waitFor({ state: "detached" });
        expect((await probe()).started).toContain("opacity transition");
      } finally {
        await page.close();
      }
    });
});
