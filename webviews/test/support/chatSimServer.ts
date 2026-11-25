// The chat simulator's harness page (test/browser/chat-sim.html) on a Vite server: the one setup the
// browser lane (chat-sim-browser.test.ts) and the watch command (scripts/chat-sim-watch.ts) share.
import path from "node:path";
import type { ViteDevServer } from "vite";
import { warmViteServer } from "./warmDevServer";

export const CHAT_SIM_PAGE = "/test/browser/chat-sim.html";

/** Starts Vite on the webviews root, warms the harness page and returns the server and its base URL. */
export async function startChatSimServer(): Promise<{ vite: ViteDevServer; base: string }> {
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "../..");
  const vite = await createServer({
    root: webviews,
    configFile: path.join(webviews, "vite.config.ts"),
    mode: "production",
    define: { "process.env.NODE_ENV": JSON.stringify("production") },
    cacheDir: path.join(webviews, "node_modules/.vite-chat-sim"),
    server: { port: 0, host: "127.0.0.1", strictPort: false },
    logLevel: "error",
  });
  await vite.listen();
  await warmViteServer(vite, CHAT_SIM_PAGE);
  const { port } = vite.httpServer!.address() as { port: number };
  return { vite, base: `http://127.0.0.1:${port}` };
}
