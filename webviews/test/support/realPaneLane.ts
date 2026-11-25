// One browser lane of the real agent pane against the real acpmux daemon (realAcpmux.ts): the pane's
// Vite dev server, the daemon behind the app-transport relay, and headless Chromium. A file calls
// realPaneLane inside its requireBrowserLane callback.
//
// Where it runs: the agent pane real-daemon job (ci-web.yml `agent-pane-real-acpmux`) builds acpmux
// and sets CMUX_REAL_ACPMUX=1, which makes a missing binary a failure. Elsewhere (the webview
// shards, which build no Rust) a file skips, naming why, when this host has no acpmux built.
import { describe, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import {
  acpmuxBinary,
  realAcpmuxRequired,
  startRealAcpmux,
  type RealAcpmux,
  type RealAcpmuxOptions,
} from "./realAcpmux";
import { warmViteServer } from "./warmDevServer";

export type RealPaneLane = {
  daemon: RealAcpmux;
  browser: Browser;
  /** The pane page's origin. */
  base: string;
  close: () => Promise<void>;
};

/** Runs `register` when this host has acpmux built; otherwise one skipped (or, required, failing) test names why. */
export async function realPaneLane(file: string, register: () => void | Promise<void>): Promise<void> {
  if (acpmuxBinary()) return register();
  const why = "no acpmux binary (set ACPMUX_BIN or build cmux-tui's acpmux)";
  if (realAcpmuxRequired()) {
    test(`${file}: the real-daemon lane runs`, () => {
      throw new Error(`${file}: CMUX_REAL_ACPMUX=1 but ${why}`);
    });
    return;
  }
  console.warn(`${file}: skipping: ${why}`);
  describe.skip(file, () => test(why, () => {}));
}

export async function openRealPaneLane(options: Omit<RealAcpmuxOptions, "pageOrigin"> = {}): Promise<RealPaneLane> {
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "../..");
  const vite = await createServer({
    configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
    server: { port: 0, host: "127.0.0.1", strictPort: false },
    logLevel: "error",
  });
  await vite.listen();
  // The pane's module graph (direct.ts and App.tsx each past Babel's 500 KB) warmed in 45-55 s on an
  // idle runner and past warmDevServer's default 100 s on a busy one, which failed every file of the
  // real-daemon job in beforeAll (cmux#52044, 2026-11-24). 180 s still fits each file's own limit.
  await warmViteServer(vite, "/", { timeoutMs: 180_000 });
  const { port } = vite.httpServer!.address() as { port: number };
  const base = `http://127.0.0.1:${port}`;
  const daemon = await startRealAcpmux({ ...options, pageOrigin: base });
  const browser = await chromium.launch({ headless: true });
  return {
    daemon,
    browser,
    base,
    async close() {
      await browser.close();
      await vite.close();
      await daemon.stop();
    },
  };
}

/**
 * Runs `body`; when it throws, leaves what the page and acpmux showed in FAST_CHECKS_OUT (a
 * screenshot, the pane's chat state and text, the frames the relay carried, the daemon's log) and
 * throws again.
 */
export async function withFailureDump<T>(
  lane: RealPaneLane,
  page: Page,
  name: string,
  body: () => Promise<T>,
): Promise<T> {
  try {
    return await body();
  } catch (error) {
    const out = process.env.FAST_CHECKS_OUT;
    if (out) {
      const { mkdirSync, writeFileSync } = await import("node:fs");
      mkdirSync(out, { recursive: true });
      const at = (file: string) => path.join(out, `${name}-failed-${file}`);
      await page.screenshot({ path: at("page.png") }).catch(() => {});
      const state = await page
        .evaluate(() => ({
          url: location.href,
          chatState: (window as any).cmuxAcpmuxDebug?.chatState?.(),
          text: document.body.innerText.slice(0, 4000),
        }))
        .catch((e) => ({ error: String(e) }));
      writeFileSync(at("state.json"), JSON.stringify(state, null, 1));
      const tail = (frames: unknown[]) => frames.slice(-200).map((f) => JSON.stringify(f).slice(0, 2000));
      writeFileSync(at("sent.jsonl"), tail(lane.daemon.sent).join("\n"));
      writeFileSync(at("received.jsonl"), tail(lane.daemon.received).join("\n"));
      writeFileSync(at("daemon.log"), lane.daemon.log().slice(-200_000));
    }
    throw error;
  }
}

/** Waits until the shown chat's turn ended with a reply; returns the chat's session id. */
export async function turnDone(page: Page, timeout = 60_000): Promise<string> {
  const handle = await page.waitForFunction(
    () => {
      const state = (window as any).cmuxAcpmuxDebug?.chatState?.();
      return state?.sessionId && state.lastAssistant && !state.isWorking ? state.sessionId : null;
    },
    undefined,
    { timeout },
  );
  return (await handle.jsonValue()) as string;
}
