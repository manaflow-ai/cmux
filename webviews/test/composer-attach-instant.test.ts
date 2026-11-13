// Leo, 2026-11-07, on a pasted screenshot's chip in a chat on this Mac with a retry arrow over its
// thumbnail: "do we EVER block them? we dont need to right? since they're local chats anyways? idk
// why we even show the retry symbol then (do we even retry? i mean it's just going to the path
// right? heck can't we make this all "appear" a lot faster if stuff's just file paths at a certain
// point?"
//
// A pasted image shows its picture at once, from the file itself (a `data:` URL the browser makes
// off the main thread), while its preview is still being made: never a blank spinner tile until
// the scale and base64 step ends.
//
// The page is the pane's dev entry with the in-page mock transport.
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("composer-attach-instant.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-attach-instant: skipping (run `bunx playwright install chromium`)");
    describe.skip("instant attachments", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
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

  async function newChat(): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 900, height: 640 } });
    await page.addInitScript(() => {
      Object.assign(window, {
        webkit: {
          messageHandlers: {
            agentSession: { postMessage: async () => ({ ok: true, value: null }) },
          },
        },
        cmuxAcpmuxActions: {
          ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true }),
        },
      });
    });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(".acpmux-composer-prompt").waitFor();
    return page;
  }

  /// Pastes one Retina screenshot and answers how long, from the
  /// paste, until a picture first showed in the prompt (an `img` drawn with pixels), and whether its
  /// chip was still loading then.
  const pasteAndTime = (page: Page) =>
    page.evaluate(async () => {
      // A Retina screenshot of an app: flat panels, rules and lines of text.
      const canvas = document.createElement("canvas");
      canvas.width = 2880;
      canvas.height = 1800;
      const context = canvas.getContext("2d")!;
      context.fillStyle = "#1b1c20";
      context.fillRect(0, 0, canvas.width, canvas.height);
      context.fillStyle = "#24262b";
      context.fillRect(0, 0, 520, canvas.height);
      context.font = "28px sans-serif";
      for (let line = 0; line < 60; line += 1) {
        context.fillStyle = line % 7 === 0 ? "#6aa2ff" : "#d6d7db";
        context.fillText(
          `${line} const attachment = await intake(file, { preview: true }); // ${"x".repeat(line % 40)}`,
          560,
          40 + line * 29,
        );
        context.fillText(`Session ${line}`, 32, 40 + line * 29);
      }
      const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
      const data = new DataTransfer();
      data.items.add(new File([blob], "Screenshot.png", { type: "image/png" }));
      const target = document.querySelector(".acpmux-composer-prompt [contenteditable='true']")!;
      const prompt = target.closest(".acpmux-composer-prompt")!;
      // Only the chip this paste makes: the earlier pastes' pictures are already in the prompt.
      const before = new Set(prompt.querySelectorAll(".acpmux-md-inline-chip"));
      const seen = new Promise<{ ms: number; whileLoading: boolean }>((resolve) => {
        const started = performance.now();
        const look = () => {
          for (const img of prompt.querySelectorAll<HTMLImageElement>("img")) {
            if (!img.complete || img.naturalWidth === 0) continue;
            const chip = img.closest(".acpmux-md-inline-chip");
            if (!chip || before.has(chip)) continue;
            return resolve({
              ms: performance.now() - started,
              whileLoading: chip?.getAttribute("data-state") === "loading",
            });
          }
          // raf-read: the measurement is the first frame a picture shows in, so it samples each one.
          requestAnimationFrame(look);
        };
        // raf-read: the same sampling, from the paste's frame.
        requestAnimationFrame(look);
      });
      target.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
      return seen;
    });

  test("a pasted image shows its picture at once, before its preview is made", async () => {
    const page = await newChat();
    await page.locator(".acpmux-composer-prompt [contenteditable='true']").click();
    const runs: number[] = [];
    let whileLoading = 0;
    for (let run = 0; run < 5; run += 1) {
      const seen = await pasteAndTime(page);
      runs.push(seen.ms);
      if (seen.whileLoading) whileLoading += 1;
    }
    const sorted = [...runs].sort((a, b) => a - b);
    // The harness's number for the PR's Performance table: paste to first visible picture.
    console.log(
      `composer-attach-instant: paste to visible thumbnail ms p50=${sorted[2]!.toFixed(1)} max=${sorted[4]!.toFixed(1)} whileLoading=${whileLoading}/5 runs=${runs.map((ms) => ms.toFixed(1)).join(",")}`,
    );
    // Before its preview is made, in most pastes: the file's own picture decodes beside the
    // preview's scale and encode, so a fast machine may finish both in one frame now and then.
    expect(whileLoading).toBeGreaterThanOrEqual(3);
    await page.close();
  });

  // Leo, 2026-11-11, over the same paste: "this 3 stage attachment thing is still there". It was
  // empty glass, then the picture dim under that glass, then the chip coming up to full: a pasted
  // image now shows once, as its picture at full strength, and the chip it becomes changes nothing.
  test("a pasted image shows in one step: its picture at full strength from its first frame", async () => {
    const page = await newChat();
    await page.locator(".acpmux-composer-prompt [contenteditable='true']").click();
    const frames = await page.evaluate(async () => {
      const canvas = document.createElement("canvas");
      canvas.width = 1600;
      canvas.height = 1000;
      const context = canvas.getContext("2d")!;
      context.fillStyle = "#1b1c20";
      context.fillRect(0, 0, canvas.width, canvas.height);
      context.fillStyle = "#6aa2ff";
      context.fillRect(200, 200, 800, 400);
      const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
      const data = new DataTransfer();
      data.items.add(new File([blob], "Screenshot.png", { type: "image/png" }));
      const target = document.querySelector(".acpmux-composer-prompt [contenteditable='true']")!;
      const prompt = target.closest(".acpmux-composer-prompt")!;
      /// Each frame's look of the pasted chip, from the paste until it is ready and settled.
      const seen: { state: string; picture: boolean; opacity: number }[] = [];
      const done = new Promise<void>((resolve) => {
        let settled = 0;
        const look = () => {
          const chip = prompt.querySelector<HTMLElement>(".acpmux-md-inline-chip");
          if (chip && getComputedStyle(chip).visibility !== "hidden" && chip.getBoundingClientRect().width > 0) {
            const img = chip.querySelector<HTMLImageElement>("img");
            const picture = Boolean(img?.complete && img.naturalWidth > 0);
            const opacity = Number(getComputedStyle(chip).opacity) * (img ? Number(getComputedStyle(img).opacity) : 1);
            seen.push({ state: chip.getAttribute("data-state") ?? "", picture, opacity });
            if (chip.getAttribute("data-state") === "ready" && (settled += 1) > 20) return resolve();
          }
          // raf-read: the look is per frame, so it samples each one.
          requestAnimationFrame(look);
        };
        // raf-read: the same sampling, from the paste's frame.
        requestAnimationFrame(look);
      });
      target.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
      await done;
      return seen;
    });
    // No frame shows the tile without its picture, or with the picture dimmed.
    expect(frames.length).toBeGreaterThan(0);
    expect(frames.filter((frame) => !frame.picture)).toEqual([]);
    expect(frames.filter((frame) => frame.opacity < 0.99)).toEqual([]);
    await page.close();
  });
});
