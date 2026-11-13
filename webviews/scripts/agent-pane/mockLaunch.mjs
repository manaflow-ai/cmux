// The dev server and browser the mock-mode drivers share: compare.mjs (scored captures) and
// first-user-journey/run.mjs (the click-through matrix). Each starts a Vite dev server on a free
// port, launches Chrome (the bundled Chromium where no Chrome is installed, as on a Linux CI
// worker), and stubs the host bridge so `ready` answers mock and the page runs the real acpmux
// client against the in-page daemon (src/agent-session/acpmux/mock.ts).
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createServer } from "vite";
import { chromium } from "playwright";

export const webviews = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

/// A dev server for `config` (a file in webviews/) on a free loopback port: `{ url, close }`.
export async function startDevServer(config) {
  const server = await createServer({
    configFile: path.join(webviews, config),
    server: { host: "127.0.0.1", port: 0, strictPort: false },
    logLevel: "error",
  });
  await server.listen();
  return { url: server.resolvedUrls.local[0], close: () => server.close() };
}

/// The browser the tests use (test/support/systemChrome.ts): the patched chrome-headless-shell that
/// scripts/ci/ensure-system-chrome.sh fetched (`CMUX_CHROME_HEADLESS_SHELL`), else the system Chrome.
/// Playwright's bundled Chromium only when asked (`CMUX_PLAYWRIGHT_BUNDLED_CHROMIUM=1`): it lags the
/// security fixes. Never on a Mac outside GitHub Actions (no Playwright on Macs).
export async function launchBrowser() {
  if (process.platform === "darwin" && process.env.GITHUB_ACTIONS !== "true")
    throw new Error("browser lane: not on a Mac (no Playwright on Macs); run it in CI or on a cloud VM");
  if (process.env.CMUX_PLAYWRIGHT_BUNDLED_CHROMIUM === "1") return chromium.launch();
  const shell = process.env.CMUX_CHROME_HEADLESS_SHELL;
  return shell ? chromium.launch({ executablePath: shell }) : chromium.launch({ channel: "chrome" });
}

/// Before the page loads: the host bridge answers `ready` with the mock transport, and `script` (a
/// recorded MockScript, optional) replaces the daemon's scripted turn. `globals` are set on window
/// first: the mock daemon's fixture hooks (`cmuxAcpmuxMock*`). `ready` adds fields to the handshake
/// (`newSession: true` opens a new chat instead of the seeded one).
export function stubMockBridge(page, { script, globals, ready } = {}) {
  return page.addInitScript(
    ({ script, globals, ready }) => {
      Object.assign(window, globals ?? {});
      if (script) window.cmuxAcpmuxMockScript = script;
      window.cmuxAcpmuxActions = {
        ready: async () => ({ protocolVersion: 1, transport: "mock", ...ready }),
      };
    },
    { script, globals, ready },
  );
}

/// Two animation frames: React has committed and the browser has painted.
export function settle(page) {
  return page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
}
