// l10n-allow-file: typed fixture text, not shipped UI.
// Leo, 2026-11-18: the composer's preview bounces, and its buttons belong at the bottom.
//
// The chat composer's box grows up from its bottom edge. Its controls (+, the mic, Send) sit at that
// bottom edge, centered on a one-line prompt's line, and stay there in every painted frame:
// - while the prompt grows from one line to eight, line by line, and on to its cap;
// - while an attachment's preview comes in (a paste), and while it goes (Backspace);
// - while a pasted text chip comes in.
// On the first line (the base before this test) they rode the box's rising top edge up with each line
// and with each preview, then fell back when the preview went or the draft reached its cap.
//
// Both looks (Claude's and Codex's) at a wide and a narrow pane, from the pane's dev entry with the
// in-page mock transport. Frames are read after paint (support/paintedFrames.ts).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdirSync } from "node:fs";
import { chromium, type Browser, type Page } from "playwright";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { installPaintedFrames } from "./support/paintedFrames";
import { COMPOSER_EDITOR } from "../src/agent-session/acpmux/composerSelectors";

type Edge = { top: number; bottom: number };
type Frame = { box: Edge; controls: Edge[]; tile: Edge | null };

await requireBrowserLane("composer-buttons-bottom.test.ts", async () => {
  if (!(await probeEngineOrSkip("composer buttons bottom", "chromium", chromium))) return;
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const out = process.env.FAST_CHECKS_OUT ?? path.join(webviews, "artifacts", "composer-buttons-bottom");
  mkdirSync(out, { recursive: true });
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function newChat(width: number, look: "claude" | "codex"): Promise<Page> {
    // Tall enough for a new chat with a draft at its cap (12 lines): a shorter pane runs the capped box
    // past its own bottom edge, a separate case this file does not measure.
    const page = await browser.newPage({ viewport: { width, height: 1000 } });
    await page.addInitScript((look) => {
      try {
        localStorage.setItem("cmux.composer.look", look);
      } catch {}
      Object.assign(window, {
        webkit: { messageHandlers: { agentSession: { postMessage: async () => ({ ok: true, value: null }) } } },
        cmuxAcpmuxActions: { ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true }) },
      });
    }, look);
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(".acpmux-composer-prompt").waitFor();
    await page.locator(COMPOSER_EDITOR).click();
    await page.evaluate(() => document.fonts.ready);
    await installPaintedFrames(page);
    return page;
  }

  /** Starts reading every painted frame: the box, + and the trailing actions (the mic, and Send once
   *  there is a draft), and the first attachment tile. */
  const record = (page: Page) =>
    page.evaluate(() => {
      const edge = (el: Element | null | undefined) => {
        if (!el) return null;
        const b = el.getBoundingClientRect();
        return b.width > 0 ? { top: b.top, bottom: b.bottom } : null;
      };
      const frames: unknown[] = [];
      const stop = window.cmuxAfterPaint(() => {
        const box = document.querySelector(".acpmux-composer-box")!;
        frames.push({
          box: edge(box),
          controls: [...box.querySelectorAll(".acpmux-composer-plus button, .acpmux-composer-actions")]
            .map(edge)
            .filter(Boolean),
          tile: edge(box.querySelector(".acpmux-md-inline-chip, .acpmux-attachments .acpmux-attachment")),
        });
      });
      Object.assign(window, { __buttons: { frames, stop } });
    });
  const frames = async (page: Page): Promise<Frame[]> => {
    for (let i = 0; i < 12; i++) await page.evaluate(() => window.cmuxPaintFrame());
    return page.evaluate(() => {
      const state = (window as unknown as { __buttons: { frames: Frame[]; stop(): void } }).__buttons;
      state.stop();
      return state.frames;
    });
  };
  const settle = (page: Page) =>
    page.waitForFunction(() => document.querySelector(".acpmux-md-field")!.getAnimations().length === 0);

  /** Every case's numbers, printed together once the file ends (a fleet log keeps its tail). */
  const summary: string[] = [];
  afterAll(() => console.log(`composer-buttons-bottom summary\n${summary.join("\n")}`));

  /** How many of `all` moved a control off `rest`'s place (on screen, or off the box's bottom edge),
   *  and the most it moved (px). Each case is measured before any is judged, so a red run reports
   *  every case's numbers. `screen` and `edge` say which way it moved; `box` is how far the box's
   *  own bottom edge moved. */
  function still(label: string, rest: Frame, all: Frame[]) {
    expect(all.length).toBeGreaterThan(0);
    let worst = 0;
    let moved = 0;
    let screen = 0;
    let edge = 0;
    let box = 0;
    for (const frame of all) {
      expect(frame.controls.length).toBe(rest.controls.length);
      let off = 0;
      box = Math.max(box, Math.abs(frame.box.bottom - rest.box.bottom));
      frame.controls.forEach((control, index) => {
        const was = rest.controls[index]!;
        const onScreen = Math.abs(control.top - was.top);
        const offEdge = Math.abs(frame.box.bottom - control.bottom - (rest.box.bottom - was.bottom));
        screen = Math.max(screen, onScreen);
        edge = Math.max(edge, offEdge);
        off = Math.max(off, onScreen, offEdge);
      });
      worst = Math.max(worst, off);
      if (off > 0.5) moved++;
    }
    const line = `${label}: ${moved}/${all.length} frames moved a control, at most ${worst.toFixed(1)}px (screen ${screen.toFixed(1)}, off the box's bottom ${edge.toFixed(1)}, box bottom ${box.toFixed(1)})`;
    console.log(`composer-buttons-bottom ${line}`);
    summary.push(line);
    return { label, moved, worst: Math.round(worst) };
  }
  type Result = ReturnType<typeof still>;
  const allStill = (results: Result[]) =>
    expect(results).toEqual(results.map((result) => ({ ...result, moved: 0, worst: 0 })));

  const paste = (page: Page, text?: string) =>
    page.evaluate(
      async ({ prompt, text }) => {
        const data = new DataTransfer();
        if (text) data.setData("text/plain", text);
        else {
          const canvas = document.createElement("canvas");
          canvas.width = 1600;
          canvas.height = 1000;
          const context = canvas.getContext("2d")!;
          context.fillStyle = "#335";
          context.fillRect(0, 0, 1600, 1000);
          const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
          data.items.add(new File([blob], "shot.png", { type: "image/png" }));
        }
        const event = new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true });
        if (event.clipboardData !== data) Object.defineProperty(event, "clipboardData", { value: data });
        document.querySelector(prompt)!.dispatchEvent(event);
      },
      { prompt: COMPOSER_EDITOR, text },
    );
  const restFrame = async (page: Page) => {
    await record(page);
    return (await frames(page)).at(-1)!;
  };

  for (const look of ["claude", "codex"] as const)
    for (const width of [900, 420])
      describe(`${look} look, ${width} px pane`, () => {
        test("the controls keep the box's bottom while the prompt grows from one line to eight and to its cap", async () => {
          const page = await newChat(width, look);
          try {
            await page.keyboard.type("line 1");
            await settle(page);
            const rest = await restFrame(page);
            await record(page);
            for (let n = 2; n <= 8; n++) {
              await page.keyboard.press("Shift+Enter");
              await page.keyboard.type(`line ${n}`);
              await settle(page);
            }
            await page.screenshot({ path: path.join(out, `${look}-w${width}-eight-lines.png`) });
            for (let n = 9; n <= 24; n++) {
              await page.keyboard.press("Shift+Enter");
              await page.keyboard.type(`line ${n}`);
            }
            await settle(page);
            const grown = await frames(page);
            // The box did grow: the test measured a growing composer.
            expect(grown.at(-1)!.box.top).toBeLessThan(rest.box.top - 100);
            allStill([still(`${look} w${width} grow`, rest, grown)]);
          } finally {
            await page.close();
          }
        });

        for (const view of ["inline", "strip"] as const)
          test(`${view} view: the controls keep the box's bottom while an image preview comes and goes, and a pasted text chip comes`, async () => {
            const page = await newChat(width, look);
            const tag = `${look}-w${width}-${view}`;
            try {
              if (view === "strip") await page.evaluate(() => window.cmuxAcpmuxComposer?.({ attachmentView: "strip" }));
              const rest = await restFrame(page);
              await page.screenshot({ path: path.join(out, `${tag}-empty.png`) });
              const results: Result[] = [];
              await record(page);
              await paste(page);
              await page.waitForFunction(() => {
                const box = document.querySelector(".acpmux-composer-box")!;
                const img = box.querySelector<HTMLImageElement>(".acpmux-attachment-image img");
                return !box.querySelector('[aria-busy="true"]') && !!img?.complete && img.naturalWidth > 0;
              });
              await settle(page);
              const coming = await frames(page);
              expect(coming.some((frame) => frame.tile)).toBe(true);
              await page.screenshot({ path: path.join(out, `${tag}-with-preview.png`) });
              results.push(still(`${tag} preview in`, rest, coming));
              // Once drawn, the preview itself never moves on screen until it goes.
              const shown = coming.filter((frame) => frame.tile);
              const last = shown.at(-1)!.tile!;
              const off = shown.map((frame) =>
                Math.max(Math.abs(frame.tile!.top - last.top), Math.abs(frame.tile!.bottom - last.bottom)),
              );
              const tile = {
                label: `${tag} preview tile`,
                moved: off.filter((each) => each > 0.5).length,
                worst: Math.round(Math.max(...off)),
              };
              console.log(
                `composer-buttons-bottom ${tile.label}: ${tile.moved}/${shown.length} frames moved it, at most ${tile.worst}px`,
              );
              results.push(tile);
              summary.push(`${tile.label}: ${tile.moved}/${shown.length} frames moved it, at most ${tile.worst}px`);
              await record(page);
              await page.keyboard.press("Backspace");
              await page.waitForFunction(
                () => !document.querySelector(".acpmux-composer-box :is(.acpmux-md-inline-chip, .acpmux-attachments)"),
              );
              await settle(page);
              results.push(still(`${tag} preview out`, rest, await frames(page)));
              await record(page);
              await paste(page, Array.from({ length: 80 }, (_, i) => `pasted line ${i}`).join("\n"));
              await settle(page);
              results.push(still(`${tag} pasted text`, rest, await frames(page)));
              allStill(results);
            } finally {
              await page.close();
            }
          });
      });
});
