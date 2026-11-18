import { expect, test } from "bun:test";
import type { IncomingMessage, ServerResponse } from "node:http";
import type { ViteDevServer } from "vite-plus";
import path from "node:path";
import { agentPaneHost, cmuxDevServer } from "../dev-server/plugins";

const root = "/work/cmux/webviews";

for (const [cacheDir, request] of [
  [root + "/node_modules/.vite-dev-deps-4292", "/node_modules/.vite-dev-deps-4292/deps/react.js"],
  [root + "/node_modules/.custom-cache", "/node_modules/.custom-cache/deps/react.js"],
  ["/tmp/chatparity-stable/vite-pages-cache", "/@fs/tmp/chatparity-stable/vite-pages-cache/deps/react.js"],
  ["/tmp/chat parity/cache", "/@fs/tmp/chat%20parity/cache/deps/react.js"],
] as const) {
  test(`optimized modules in ${cacheDir} revalidate after a dependency graph changes`, async () => {
    const plugin = cmuxDevServer().find((item) => item.name === "cmux-dev-server")!;
    const hook = plugin.configureServer;
    if (typeof hook !== "function") throw new Error("Missing dev-server middleware");
    type Middleware = (req: IncomingMessage, response: ServerResponse, next: () => void) => void;
    const middleware: Middleware[] = [];
    await hook.call(
      {} as never,
      {
        config: { root, cacheDir, server: { port: 4292 } },
        middlewares: {
          use: (handler: Middleware) => {
            middleware.push(handler);
          },
        },
      } as unknown as ViteDevServer,
    );
    for (const [url, expected] of [
      [request + "?v=same-hash", "no-cache"],
      ["/src/main.tsx", "max-age=31536000,immutable"],
      [request.replace("/deps/", "-other/deps/"), "max-age=31536000,immutable"],
    ]) {
      const headers = new Map<string, string>();
      const response = {
        setHeader: (name: string, value: string) => {
          headers.set(name.toLowerCase(), value);
        },
      };
      const dispatch = (at: number): void => {
        const handler = middleware[at];
        if (handler) handler({ url } as IncomingMessage, response as unknown as ServerResponse, () => dispatch(at + 1));
        else response.setHeader("Cache-Control", "max-age=31536000,immutable");
      };
      dispatch(0);
      expect(headers.get("cache-control"), url).toBe(expected);
    }
  });
}

test("the standalone agent pane revalidates optimized modules too", async () => {
  const plugin = agentPaneHost();
  const hook = plugin.configureServer;
  if (typeof hook !== "function") throw new Error("Missing agent-pane middleware");
  type Middleware = (req: IncomingMessage, response: ServerResponse, next: () => void) => void;
  const middleware: Middleware[] = [];
  await hook.call(
    {} as never,
    {
      config: {
        root: path.resolve(import.meta.dir, "../src/agent-session/acpmux"),
        cacheDir: "/tmp/chatparity-agent-cache",
        server: { port: 4178 },
      },
      middlewares: {
        use: (handler: Middleware) => {
          middleware.push(handler);
        },
      },
    } as unknown as ViteDevServer,
  );
  for (const [url, expected] of [
    ["/@fs/tmp/chatparity-agent-cache/deps/react.js?v=same-hash", "no-cache"],
    ["/Composer.tsx", "max-age=31536000,immutable"],
  ]) {
    const headers = new Map<string, string>();
    const response = {
      setHeader: (name: string, value: string) => {
        headers.set(name.toLowerCase(), value);
      },
    };
    const dispatch = (at: number): void => {
      const handler = middleware[at];
      if (handler) handler({ url } as IncomingMessage, response as unknown as ServerResponse, () => dispatch(at + 1));
      else response.setHeader("Cache-Control", "max-age=31536000,immutable");
    };
    dispatch(0);
    expect(headers.get("cache-control"), url).toBe(expected);
  }
});
