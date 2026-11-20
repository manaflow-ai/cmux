// The gallery dev server serves the mock app's page (src/gallery/mock-app.html) beside the shell,
// a stage and the whole app page; the view shell prototype's launcher waits on this URL.
import { afterAll, beforeAll, expect, test } from "bun:test";
import path from "node:path";

const webviews = path.resolve(import.meta.dir, "..");
const { createServer } = await import("vite");
let vite: Awaited<ReturnType<typeof createServer>> | undefined;

beforeAll(async () => {
  vite = await createServer({
    configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
    server: { port: 0, host: "127.0.0.1", strictPort: false },
    logLevel: "error",
  });
  await vite.listen();
}, 60_000);
afterAll(async () => {
  await vite?.close();
});

test("the gallery dev server serves mock-app.html and app.html", async () => {
  const port = (vite!.httpServer!.address() as { port: number }).port;
  const mock = await fetch(`http://127.0.0.1:${port}/gallery/mock-app.html`);
  expect(mock.status).toBe(200);
  expect(await mock.text()).toContain("mock-app/main.ts");
  const app = await fetch(`http://127.0.0.1:${port}/gallery/app.html`);
  expect(app.status).toBe(200);
}, 60_000);
