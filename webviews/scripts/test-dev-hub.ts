// One Vite dev server per config, and one browser server per engine, for a whole webviews test run
// (scripts/ci/run-webviews-tests.sh starts this; test/support/sharedDevServers.ts is the client).
//
// Each test file still runs in its own `bun test` process (state leaks from file to file in one
// process), but each dev server file used to start its own Vite server, which transformed the
// agent pane or the gallery's ~2,300 modules from scratch, and its own browser. Those boots were
// most of a shard's wall time: dev server files were 556 of 2,666 files and 17,200 of 23,173
// file-seconds (manifest of run 43316239090). Here a test file's `createServer(config)` gets the
// one server this hub runs for that config, already warm from the files before it, and its
// `chromium.launch(options)` a connection to one browser this hub runs for those options.
//
// HTTP on 127.0.0.1 (JSON bodies):
//   POST /vite             {config}            -> {id, port}  start or reuse the server for config
//   POST /vite/settled     {id, timeoutMs}     -> {}          wait for its optimizer (galleryFrame.ts)
//   GET  /vite/reloads?id=                     -> {sent}      full-page reloads it sent
//   POST /browser          {engine, options}   -> {wsEndpoint} start or reuse a browser server
//
//   bun scripts/test-dev-hub.ts --url-file FILE --dir DIR
// prints nothing on success; writes its URL into FILE once it listens. SIGTERM closes every server.
import http from "node:http";
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import type { ViteDevServer } from "vite";

type ViteEntry = { id: string; port: number; server: ViteDevServer; reloads: { sent: number } };
type BrowserEntry = { wsEndpoint: string; close: () => Promise<void> };

const args = process.argv.slice(2);
const flag = (name: string) => {
  const at = args.indexOf(name);
  return at >= 0 ? args[at + 1] : undefined;
};
const urlFile = flag("--url-file");
const dir = flag("--dir") ?? fs.mkdtempSync(path.join(process.env.TMPDIR ?? "/tmp", "cmux-test-dev-hub-"));
if (!urlFile) {
  console.error("usage: bun scripts/test-dev-hub.ts --url-file FILE [--dir DIR]");
  process.exit(2);
}
fs.mkdirSync(dir, { recursive: true });

const vites = new Map<string, Promise<ViteEntry>>();
const viteById = new Map<string, ViteEntry>();
const browsers = new Map<string, Promise<BrowserEntry>>();

const keyOf = (value: unknown) => createHash("sha256").update(JSON.stringify(value)).digest("hex").slice(0, 16);

async function startVite(config: Record<string, unknown>): Promise<ViteEntry> {
  const id = keyOf(config);
  const { createServer } = await import("vite");
  // Each config optimizes into a folder of its own: two configs on one cache lose each other's
  // optimized files (run-webviews-tests.sh says why). A config that names its own keeps it.
  const server = await createServer({ ...config, ...(config.cacheDir ? {} : { cacheDir: path.join(dir, `vite-${id}`) }) });
  await server.listen();
  const reloads = { sent: 0 };
  const hot = server.environments.client.hot;
  const send = hot.send;
  hot.send = ((...sent: Parameters<typeof send>) => {
    if ((sent[0] as { type?: string } | undefined)?.type === "full-reload") reloads.sent += 1;
    return (send as (...rest: unknown[]) => void).apply(hot, sent);
  }) as typeof send;
  const port = (server.httpServer!.address() as { port: number }).port;
  const entry = { id, port, server, reloads };
  viteById.set(id, entry);
  return entry;
}

/** The galleryFrame.ts wait, run where the server is: requests idle and no dependency still bundling. */
async function settled(server: ViteDevServer, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  const within = async <T>(work: Promise<T>, what: string): Promise<T> => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const late = new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error(what)), Math.max(1, deadline - Date.now()));
    });
    try {
      return await Promise.race([work, late]);
    } finally {
      clearTimeout(timer);
    }
  };
  const client = server.environments.client;
  for (;;) {
    await within(client.waitForRequestsIdle(), "the dev server's requests did not go idle");
    const pending = Object.values(client.depsOptimizer?.metadata.discovered ?? {})
      .map((dep) => dep.processing)
      .filter((processing): processing is Promise<void> => processing !== undefined);
    if (pending.length === 0) break;
    await within(Promise.all(pending), "the dependency optimizer did not settle");
  }
  await new Promise((resolve) => setImmediate(resolve));
}

async function startBrowser(engine: string, options: Record<string, unknown>): Promise<BrowserEntry> {
  const playwright = await import("playwright");
  const type = (playwright as unknown as Record<string, { launchServer: (o: unknown) => Promise<{ wsEndpoint(): string; close(): Promise<void> }> }>)[engine];
  if (!type || (engine !== "chromium" && engine !== "webkit" && engine !== "firefox")) throw new Error(`no engine ${engine}`);
  let launch = options;
  if (engine === "chromium" && process.env.CMUX_PLAYWRIGHT_BUNDLED_CHROMIUM !== "1") {
    // The same Chrome test/preload.ts gives a file's own launch (support/systemChrome.ts).
    const shell = process.env.CMUX_CHROME_HEADLESS_SHELL || undefined;
    if (!("channel" in options) && !("executablePath" in options))
      launch = shell && options.headless !== false ? { ...options, executablePath: shell } : { ...options, channel: "chrome" };
  }
  const server = await type.launchServer(launch);
  return { wsEndpoint: server.wsEndpoint(), close: () => server.close() };
}

function once<T>(map: Map<string, Promise<T>>, key: string, start: () => Promise<T>): Promise<T> {
  let entry = map.get(key);
  if (!entry) {
    entry = start();
    // A start that failed is tried again by the next file, not cached as a failure for all of them.
    entry.catch(() => map.delete(key));
    map.set(key, entry);
  }
  return entry;
}

async function body(request: http.IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  for await (const chunk of request) chunks.push(chunk as Buffer);
  return chunks.length ? (JSON.parse(Buffer.concat(chunks).toString("utf8")) as Record<string, unknown>) : {};
}

const hub = http.createServer(async (request, response) => {
  const reply = (status: number, value: unknown) => {
    response.writeHead(status, { "content-type": "application/json" });
    response.end(JSON.stringify(value));
  };
  try {
    const url = new URL(request.url ?? "/", "http://hub");
    if (request.method === "POST" && url.pathname === "/vite") {
      const { config } = (await body(request)) as { config: Record<string, unknown> };
      const entry = await once(vites, keyOf(config), () => startVite(config));
      return reply(200, { id: entry.id, port: entry.port });
    }
    if (request.method === "POST" && url.pathname === "/vite/settled") {
      const { id, timeoutMs } = (await body(request)) as { id: string; timeoutMs: number };
      const entry = viteById.get(id);
      if (!entry) return reply(404, { error: `no server ${id}` });
      await settled(entry.server, timeoutMs);
      return reply(200, {});
    }
    if (request.method === "GET" && url.pathname === "/vite/reloads") {
      const entry = viteById.get(url.searchParams.get("id") ?? "");
      if (!entry) return reply(404, { error: "no such server" });
      return reply(200, { sent: entry.reloads.sent });
    }
    if (request.method === "POST" && url.pathname === "/browser") {
      const { engine, options } = (await body(request)) as { engine: string; options: Record<string, unknown> };
      const entry = await once(browsers, keyOf([engine, options]), () => startBrowser(engine, options ?? {}));
      return reply(200, { wsEndpoint: entry.wsEndpoint });
    }
    reply(404, { error: `no route ${request.method} ${url.pathname}` });
  } catch (error) {
    reply(500, { error: String((error as Error)?.stack ?? error) });
  }
});

let closing = false;
async function shutdown() {
  if (closing) return;
  closing = true;
  hub.close();
  const all = [
    ...[...vites.values()].map((entry) => entry.then((vite) => vite.server.close())),
    ...[...browsers.values()].map((entry) => entry.then((browser) => browser.close())),
  ];
  await Promise.race([Promise.allSettled(all), new Promise((resolve) => setTimeout(resolve, 10_000))]);
  process.exit(0);
}
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);

hub.listen(0, "127.0.0.1", () => {
  const { port } = hub.address() as { port: number };
  const temp = `${urlFile}.tmp`;
  fs.writeFileSync(temp, `http://127.0.0.1:${port}\n`);
  fs.renameSync(temp, urlFile);
});
