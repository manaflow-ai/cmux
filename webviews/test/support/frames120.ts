// A Chromium page whose frames come at a 120 Hz display's pace (8.33 ms), for motion checks.
//
// Headless Chromium draws at 60 Hz and has no refresh-rate switch. With BeginFrame control
// (`--enable-begin-frame-control`, a target made with `enableBeginFrameControl`) it draws only when
// asked (`HeadlessExperimental.beginFrame`), so this asks every 8.33 ms of wall time: timers, the
// socket's stand-ins and frame callbacks all run on the real clock, and a frame whose work runs past
// its slot misses the next one, as on a 120 Hz display. Each frame's time from the ask until Chromium
// drew it is its frame time; a slot no frame began in is a dropped frame.
import net from "node:net";
import { chromium, type Browser, type Page } from "playwright";

export const FRAME_MS = 1000 / 120;

/// The browser cannot draw on a test's clock: a full Chrome, not chrome-headless-shell (set
/// CMUX_CHROME_HEADLESS_SHELL; scripts/ci/ensure-system-chrome.sh fetches it).
export class FramesUnsupported extends Error {}

export type FramePacing = {
  /// Each drawn frame's time, ask to drawn (ms), in order.
  frameMs: number[];
  /// Slots of the 120 Hz clock no frame began in.
  dropped: number;
};

export type Frames120 = {
  page: Page;
  /// Starts asking for frames; `stop` ends it and returns the pacing since `start`.
  start(): void;
  stop(): Promise<FramePacing>;
  close(): Promise<void>;
};

async function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address() as net.AddressInfo;
      server.close(() => resolve(port));
    });
  });
}

/// Opens `url` in a new headless Chromium whose page draws only on this clock's frames. The clock
/// runs from the page's creation (it draws nothing otherwise); `start`/`stop` mark the measured span.
export async function open120Hz(url: string, viewport = { width: 900, height: 640 }): Promise<Frames120> {
  const port = await freePort();
  const owner = await chromium.launch({
    headless: true,
    args: [
      `--remote-debugging-port=${port}`,
      "--enable-begin-frame-control",
      "--run-all-compositor-stages-before-draw",
    ],
  });
  let browser: Browser | undefined;
  try {
    browser = await chromium.connectOverCDP(`http://127.0.0.1:${port}`);
    const context = browser.contexts()[0]!;
    const opened = context.waitForEvent("page");
    const session = await browser.newBrowserCDPSession();
    await session.send("Target.createTarget", {
      // The page's own URL: a navigation after creation moves it to a renderer outside the control.
      url,
      enableBeginFrameControl: true,
      width: viewport.width,
      height: viewport.height,
    } as never);
    const page = await opened;
    const cdp = await context.newCDPSession(page);
    // Only chrome-headless-shell has BeginFrame control; full Chrome's headless mode has no such
    // command, and its page would draw at 60 Hz on its own.
    try {
      await cdp.send("HeadlessExperimental.beginFrame", { interval: FRAME_MS } as never);
    } catch (error) {
      throw new FramesUnsupported(String(error));
    }
    let running = true;
    let measuring = false;
    let pacing: FramePacing = { frameMs: [], dropped: 0 };
    const pump = (async () => {
      let next = performance.now();
      while (running) {
        const now = performance.now();
        if (now < next - 1.5) {
          // fixed-wait: the 120 Hz clock: the next frame is asked for at its slot of wall time
          await new Promise((resolve) => setTimeout(resolve, Math.max(0, next - now - 1.5)));
          continue;
        }
        // The last 1.5 ms spins: a timer lands a millisecond or more late.
        while (performance.now() < next) {}
        const asked = performance.now();
        await cdp.send("HeadlessExperimental.beginFrame", { interval: FRAME_MS } as never).catch(() => undefined);
        const drawn = performance.now();
        // The next slot after the frame was drawn; slots it ran over are dropped.
        let slots = 1;
        next += FRAME_MS;
        while (next < drawn) {
          next += FRAME_MS;
          slots += 1;
        }
        if (measuring) {
          pacing.frameMs.push(drawn - asked);
          pacing.dropped += slots - 1;
        }
      }
    })();
    await page.waitForLoadState("load");
    return {
      page,
      start() {
        pacing = { frameMs: [], dropped: 0 };
        measuring = true;
      },
      async stop() {
        measuring = false;
        return pacing;
      },
      async close() {
        running = false;
        await pump;
        await browser?.close();
        await owner.close();
      },
    };
  } catch (error) {
    await browser?.close().catch(() => undefined);
    await owner.close();
    throw error;
  }
}
