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
  await warmViteServer(vite, "/");
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
