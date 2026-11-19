// l10n-allow-file: gallery fixture names are test data.
// A subagent's own composer (SubagentComposer.tsx) is the chat's composer: the same box, padding,
// radius, font and slots (+ on the left, the mic and Send on the right), with the quiet row under it
// naming the chat that passes the message on, where the chat's composer names its mode. Leo,
// 2026-11-19: "the composer is kinda odd looking for subagents" (a thin one-line box, an ↑ alone, the
// whole task title as its placeholder and "Sent through <chat>" as a loose centered caption) and
// "and it layout shifts too": the chat's composer and the subagent's stood at different heights, so
// switching the pane between them moved the box. Before that (#45911) the line stood over the
// placeholder; it still never shares a pixel row with it.
// In real Chromium (Playwright; CI fails the file when it cannot launch, requireBrowserLane), on
// gallery `agent-pane.subagents` / `own-pane-chat`, switched here from the chat to its subagent as
// the app does (a subagent: reveal):
// - the subagent's box has the chat box's place, size, radius, padding and font, and the same slots;
// - the routing note is in the quiet row, under the prompt and clear of its placeholder, which is short;
// - sampled every frame through the switch, the box never stands anywhere but its one place.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("subagent-composer-via-line.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const entry = "agent-pane.subagents";
  const variant = "own-pane-chat";

  beforeAll(async () => {
    server = await createServer({
      root: path.resolve(import.meta.dir, ".."),
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(server, entry, { browser, params: { variant } });
  });

  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  /// The composer's look and place, read the same way from the chat's and the subagent's.
  const composerLook = (page: Page) =>
    page.evaluate(() => {
      const composer = document.querySelector(".acpmux-composer")!;
      const box = composer.querySelector(".acpmux-composer-box")!;
      const prompt = composer.querySelector(".acpmux-composer-prompt .ProseMirror, .acpmux-composer-prompt")!;
      const style = getComputedStyle(box);
      const r = box.getBoundingClientRect();
      const slot = (selector: string) => {
        const node = composer.querySelector(`.acpmux-composer-box ${selector}`);
        const at = node?.getBoundingClientRect();
        return at ? { left: Math.round(at.left), width: Math.round(at.width) } : null;
      };
      const foot = composer.querySelector(".acpmux-composer-foot")?.getBoundingClientRect();
      return {
        subagent: composer.classList.contains("acpmux-subagent-composer"),
        box: { top: r.top, bottom: r.bottom, left: r.left, right: r.right },
        radius: style.borderRadius,
        padding: style.padding,
        font: `${getComputedStyle(prompt).fontFamily} ${getComputedStyle(prompt).fontSize}`,
        plus: slot(".acpmux-composer-plus"),
        mic: slot(".acpmux-fit-mic"),
        foot: foot ? { top: foot.top, height: foot.height } : null,
      };
    });

  for (const width of [760, 360]) {
    test(`the subagent's composer is the chat's, and the switch moves nothing (${width}px)`, async () => {
      const port = (server.httpServer!.address() as { port: number }).port;
      const page = await browser.newPage({ viewport: { width, height: 640 }, reducedMotion: "reduce" });
      try {
        // The chat own-pane starts from (`own-pane-chat`, no play); this page then switches it.
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        await page.locator(".acpmux-composer .acpmux-composer-box").waitFor();
        const chatLook = await composerLook(page);
        expect(chatLook.subagent).toBe(false);
        // Every frame from the switch until the subagent's composer has stood still for 30 frames.
        const frames = await page.evaluate(
          () =>
            new Promise<{ top: number; bottom: number; subagent: boolean }[]>((resolve) => {
              const seen: { top: number; bottom: number; subagent: boolean }[] = [];
              const page = window as unknown as { cmuxAcpmuxBridge?: { revealTurn?(id: string): void } };
              page.cmuxAcpmuxBridge?.revealTurn?.("subagent:agent-test-coverage");
              let still = 0;
              const tick = () => {
                const box = document.querySelector(".acpmux-composer-box")?.getBoundingClientRect();
                const subagent = Boolean(document.querySelector(".acpmux-subagent-composer"));
                if (box) seen.push({ top: box.top, bottom: box.bottom, subagent });
                still = subagent ? still + 1 : 0;
                if (still >= 30 || seen.length > 600) resolve(seen);
                else requestAnimationFrame(tick);
              };
              requestAnimationFrame(tick);
            }),
        );
        expect(frames.some((frame) => frame.subagent)).toBe(true);
        const off = frames.filter(
          (frame) => Math.abs(frame.top - chatLook.box.top) > 0.5 || Math.abs(frame.bottom - chatLook.box.bottom) > 0.5,
        );
        expect(off).toEqual([]);

        const subagentLook = await composerLook(page);
        expect(subagentLook.subagent).toBe(true);
        expect(subagentLook.box).toEqual(chatLook.box);
        expect(subagentLook.radius).toBe(chatLook.radius);
        expect(subagentLook.padding).toBe(chatLook.padding);
        expect(subagentLook.font).toBe(chatLook.font);
        expect(subagentLook.plus).toEqual(chatLook.plus);
        expect(subagentLook.mic).toEqual(chatLook.mic);
        expect(subagentLook.foot).toEqual(chatLook.foot);

        const layout = await page.evaluate(() => {
          const composer = document.querySelector(".acpmux-subagent-composer")!;
          const rect = (node: Element | Range) => {
            const r = node.getBoundingClientRect();
            return { top: r.top, bottom: r.bottom };
          };
          const via = composer.querySelector(".acpmux-subagent-via")!;
          const placeholder = composer.querySelector(".acpmux-md-placeholder")!;
          const text = placeholder.querySelector(".acpmux-md-placeholder-text") ?? placeholder;
          const range = document.createRange();
          range.selectNodeContents(text);
          return {
            box: rect(composer.querySelector(".acpmux-composer-box")!),
            via: rect(via),
            viaInFoot: Boolean(via.closest(".acpmux-composer-foot")),
            viaText: via.textContent ?? "",
            caption: composer.querySelector(".cv-subagent-composer-via") !== null,
            plusDisabled: composer.querySelector<HTMLButtonElement>(".acpmux-composer-plus button")?.disabled,
            placeholder: rect(range),
            placeholderText: text.textContent ?? "",
          };
        });
        expect(layout.viaText).toStartWith("Sent through ");
        expect(layout.viaInFoot).toBe(true);
        expect(layout.caption).toBe(false);
        expect(layout.plusDisabled).toBe(true);
        expect(layout.placeholderText).toBe("Message subagent");
        // The quiet row is under the prompt (in the box in the compact footer, under it in the plain
        // one, as the chat's): no pixel row holds both texts.
        expect(layout.via.top).toBeGreaterThanOrEqual(layout.placeholder.bottom - 0.5);
      } finally {
        await page.close();
      }
    });
  }
});
