// cmux-web-test-timeout: 300
// The app loads a page's document from the dev server only when the answer proves web-dev.json's
// token (PageDevServer.answered in CmuxNextPages); an unproven document falls back to the bundled
// one, whose bundled script (the agent pane's pane.js) the server does not have. So every HTML entry
// the server answers, the agent pane's /agent-pane/ included, must carry the proof. This runs the
// real dev server (vite.config.ts) and asks each entry with a nonce, as the app does.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { randomBytes } from "node:crypto";
import path from "node:path";
import type { ViteDevServer } from "vite";
import { DEV_NONCE_HEADER, DEV_PROOF_HEADER, devServerProof } from "../dev-server/plugins";

setDefaultTimeout(120_000);
const TOKEN = "dev-server-token-routes-test";
let server: ViteDevServer | undefined;
let base = "";
let savedToken: string | undefined;

beforeAll(async () => {
  savedToken = process.env.CMUX_WEB_DEV_TOKEN;
  process.env.CMUX_WEB_DEV_TOKEN = TOKEN;
  const { createServer } = await import("vite");
  server = await createServer({
    configFile: path.resolve(import.meta.dir, "../vite.config.ts"),
    // The test reads each entry once, so the watcher ignores everything (Vite's config merge drops a
    // `watch: null`, which left it watching the whole tree).
    server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: ["**/*"] } },
    logLevel: "error",
  });
  await server.listen();
  const { port } = server.httpServer!.address() as { port: number };
  base = `http://127.0.0.1:${port}`;
});

afterAll(async () => {
  await server?.close();
  if (savedToken === undefined) delete process.env.CMUX_WEB_DEV_TOKEN;
  else process.env.CMUX_WEB_DEV_TOKEN = savedToken;
});

describe("dev server proof on every HTML entry", () => {
  // The agent pane's document (both forms the app and web-overlay.sh use), a React page, and the
  // diff viewer's root entry.
  for (const entry of ["/agent-pane/", "/agent-pane/index.html", "/settings/", "/"]) {
    test(entry, async () => {
      const nonce = randomBytes(32).toString("hex");
      const response = await fetch(base + entry, { headers: { [DEV_NONCE_HEADER]: nonce }, redirect: "manual" });
      await response.arrayBuffer();
      expect(response.status).toBe(200);
      expect(response.headers.get("content-type") ?? "").toStartWith("text/html");
      expect(response.headers.get(DEV_PROOF_HEADER)).toBe(devServerProof(TOKEN, nonce));
    });
  }
});

// The app asks the server for a page's bundled file names first (`assets/x-hash.js`, the pane's
// pane.js) whenever the page's document came from the bundle, and serves its own copy only on a miss.
// The server used to answer every such name with its index page, a proven 200 the page ran as a
// script: blank (cmux live, Lucas 2026-11-09).
describe("a file the server lacks is a miss, not the index page", () => {
  for (const file of ["/pane.js", "/assets/index-0a1b2c3d.js", "/settings/assets/main-0a1b2c3d.js", "/chunks/x.mjs"]) {
    test(file, async () => {
      const nonce = randomBytes(32).toString("hex");
      const response = await fetch(base + file, {
        headers: { [DEV_NONCE_HEADER]: nonce, Accept: "*/*" },
        redirect: "manual",
      });
      await response.arrayBuffer();
      expect(response.status).toBe(404);
    });
  }
});

describe("cmux Live's guard and stylesheets on every HTML entry", () => {
  for (const entry of ["/agent-pane/", "/settings/"]) {
    test(entry, async () => {
      const html = await (await fetch(base + entry)).text();
      expect(html).toContain("__cmuxLiveNote");
      expect(html).toContain("/src/devkit/liveNote.dev.ts");
    });
  }

  // The app sends no Accept of the page's: the link's sheet must come back as CSS anyway.
  test("the Settings page's linked sheet is CSS for the app", async () => {
    const html = await (await fetch(base + "/settings/")).text();
    const href = html.match(/<link\b[^>]*rel="stylesheet"[^>]*href="([^"]+)"/)?.[1] ?? "";
    expect(href).toEndWith("styles.css?direct");
    const response = await fetch(new URL(href, base + "/settings/"), { headers: { Accept: "*/*" } });
    await response.arrayBuffer();
    expect(response.headers.get("content-type") ?? "").toStartWith("text/css");
  });
});
