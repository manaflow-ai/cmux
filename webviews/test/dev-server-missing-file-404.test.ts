// cmux-web-test-timeout: 300
// cmux takes a page file from the dev server unless the server answers 4xx or 5xx; then it serves
// the overlay's or the bundled copy (PageSchemeHandler.reply in CmuxNextPages). Vite's default SPA
// fallback answered every file the server does not have with the diff viewer's index.html and a 200:
// a bundled page's chunk, a stylesheet or a JSON file became HTML (the page's React content went
// blank), and a page missing from the checkout was the diff viewer. This runs the real dev server
// (vite.config.ts) and asks as the app does: a missing file is a 404, a page document is still HTML.
// A browser (no nonce) keeps the fallback, which the guest page's `/g/<share>` routes need.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { randomBytes } from "node:crypto";
import path from "node:path";
import type { ViteDevServer } from "vite";
import { DEV_NONCE_HEADER } from "../dev-server/plugins";

setDefaultTimeout(120_000);
let server: ViteDevServer | undefined;
let base = "";

beforeAll(async () => {
  const { createServer } = await import("vite");
  server = await createServer({
    configFile: path.resolve(import.meta.dir, "../vite.config.ts"),
    // Each path is read once, so the watcher ignores everything (see dev-server-token-routes.test.ts).
    server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: ["**/*"] } },
    logLevel: "error",
  });
  await server.listen();
  const { port } = server.httpServer!.address() as { port: number };
  base = `http://127.0.0.1:${port}`;
});

afterAll(async () => {
  await server?.close();
});

// As PageDevServer.request asks: a fresh nonce, and URLSession's `Accept: */*`.
const ask = (route: string) =>
  fetch(base + route, {
    headers: { Accept: "*/*", [DEV_NONCE_HEADER]: randomBytes(32).toString("hex") },
    redirect: "manual",
  });

describe("a file the dev server does not have", () => {
  for (const route of [
    "/settings/assets/index-0a1b2c3d.js",
    "/assets/missing.css",
    "/settings/strings.json",
    "/agent-pane/assets/chunk-0a1b2c3d.js",
    "/no-such-page/",
  ]) {
    test(`${route} is a 404, not another page's HTML`, async () => {
      const response = await ask(route);
      await response.arrayBuffer();
      expect(response.status).toBe(404);
    });
  }
});

describe("the documents cmux loads", () => {
  for (const route of ["/settings/", "/history/", "/agent-pane/", "/diff-page.html", "/"]) {
    test(`${route} is still HTML`, async () => {
      const response = await ask(route);
      await response.arrayBuffer();
      expect(response.status).toBe(200);
      expect(response.headers.get("content-type") ?? "").toStartWith("text/html");
    });
  }
});
