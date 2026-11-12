// A test file's Vite dev server and browser, shared with the rest of the run (scripts/test-dev-hub.ts).
//
// Every test file runs in its own `bun test` process (run-webviews-tests.sh says why), and every dev
// server file used to start a Vite server of its own, which transformed the agent pane's or the
// gallery's modules from scratch, plus a browser: those boots were most of a webview shard's wall
// time. When the runner starts a hub (CMUX_WEB_TEST_HUB, its URL), test/preload.ts calls
// installSharedDevServers, and then:
//
// - `createServer(config)` from "vite" returns a handle on the hub's one server for that config, when
//   the config is plain data (no plugins or functions), listens on port 0, is not middleware mode,
//   and the file has changed no environment variable since it started (a config reads them). The
//   handle has what test files use: listen(), close() (the hub keeps the server for the next file),
//   httpServer.address() and resolvedUrls. Anything else it is asked for throws, naming the
//   `// cmux-web-test-own-servers` header line that gives a file servers of its own.
// - With `browser` in CMUX_WEB_TEST_HUB_SHARE, `chromium.launch(options)` and `webkit.launch(options)`
//   connect to the hub's one browser server for those options (headless, plain data), and the
//   file's `browser.close()` closes only its own connection and contexts.
//
// Any other config or launch, and every file when the hub is not running (a local `bun test`, the
// base replay of an older tree), starts its own, as before.
import { mock } from "bun:test";

const SHARED = Symbol.for("cmux.sharedDevServer");

export type SharedVite = { hub: string; id: string; port: number };

/** The hub server behind a `createServer` handle, or undefined for a server the file started itself. */
export function sharedViteOf(server: unknown): SharedVite | undefined {
  if (!server || typeof server !== "object") return undefined;
  return (server as { [SHARED]?: SharedVite })[SHARED];
}

async function hubCall<T>(hub: string, route: string, payload?: unknown): Promise<T> {
  const response = await fetch(`${hub}${route}`, {
    method: payload === undefined ? "GET" : "POST",
    headers: payload === undefined ? undefined : { "content-type": "application/json" },
    body: payload === undefined ? undefined : JSON.stringify(payload),
  });
  const value = (await response.json()) as T & { error?: string };
  if (!response.ok) throw new Error(`test dev hub ${route}: ${value.error ?? response.status}`);
  return value;
}

/** Full-page reloads the hub server sent so far (galleryFrame.ts counts them around a load). */
export async function sharedViteReloads(shared: SharedVite): Promise<number> {
  return (await hubCall<{ sent: number }>(shared.hub, `/vite/reloads?id=${shared.id}`)).sent;
}

/** Waits, on the hub, until the server's requests are idle and its optimizer has settled. */
export async function sharedViteSettled(shared: SharedVite, timeoutMs: number): Promise<void> {
  await hubCall(shared.hub, "/vite/settled", { id: shared.id, timeoutMs });
}

/** Whether `value` survives JSON unchanged: no functions, class instances, RegExps or symbols. */
export function plainData(value: unknown): boolean {
  if (value === null || typeof value === "string" || typeof value === "boolean") return true;
  if (typeof value === "number") return Number.isFinite(value);
  if (value === undefined) return true;
  if (Array.isArray(value)) return value.every((item) => item !== undefined && plainData(item));
  if (typeof value !== "object") return false;
  const proto = Object.getPrototypeOf(value);
  if (proto !== Object.prototype && proto !== null) return false;
  return Object.getOwnPropertySymbols(value).length === 0 && Object.values(value).every(plainData);
}

/** Why `config` needs a server of its own, or undefined when the hub can serve it. */
export function viteOwnReason(config: unknown, envChanged: string | undefined): string | undefined {
  if (!config || typeof config !== "object") return "no inline config";
  const inline = config as Record<string, unknown>;
  if (!plainData(inline)) return "the config holds functions or objects (plugins, a watch filter)";
  const server = (inline.server ?? {}) as Record<string, unknown>;
  if (server.middlewareMode) return "middleware mode";
  if (server.port !== 0) return "a fixed port";
  if (envChanged) return `the file changed ${envChanged}`;
  return undefined;
}

/** Why a launch needs a browser of its own, or undefined when the hub's can serve it. */
export function launchOwnReason(options: unknown): string | undefined {
  if (options !== undefined && !plainData(options)) return "options hold functions or objects (a logger)";
  if ((options as { headless?: boolean } | undefined)?.headless === false) return "headed";
  return undefined;
}

function envChange(start: Record<string, string | undefined>): string | undefined {
  for (const key of new Set([...Object.keys(start), ...Object.keys(process.env)]))
    if (start[key] !== process.env[key]) return key;
  return undefined;
}

function note(message: string) {
  if (process.env.CMUX_WEB_TEST_HUB_QUIET !== "1") console.error(`test dev hub: ${message}`);
}

function handle(shared: SharedVite) {
  const url = `http://127.0.0.1:${shared.port}/`;
  const httpServer = {
    address: () => ({ port: shared.port, address: "127.0.0.1", family: "IPv4" }),
    listening: true,
  };
  const target: Record<PropertyKey, unknown> = {
    [SHARED]: shared,
    httpServer,
    resolvedUrls: { local: [url], network: [] },
    listen: async () => proxy,
    close: async () => {},
    printUrls: () => {},
  };
  const proxy: object = new Proxy(target, {
    get(object, key) {
      if (key in object) return object[key];
      // Promise resolution and inspection probe these; a handle is no thenable.
      if (typeof key === "symbol" || key === "then" || key === "toJSON") return undefined;
      throw new Error(
        `shared dev server: vite.${String(key)} is not available on the run's shared server (test/support/sharedDevServers.ts); ` +
          "add a `// cmux-web-test-own-servers` line to the file's first 20 lines for a server of its own",
      );
    },
  });
  return proxy;
}

/** Routes this file's dev servers (and, when shared, browsers) to the run's hub. */
export async function installSharedDevServers(hub: string): Promise<void> {
  const start = { ...process.env };
  const share = new Set((process.env.CMUX_WEB_TEST_HUB_SHARE ?? "vite").split(",").map((item) => item.trim()));

  if (share.has("vite")) {
    const real = await import("vite");
    const createServer = real.createServer;
    const shared = async (config?: Parameters<typeof createServer>[0]) => {
      const reason = viteOwnReason(config, envChange(start));
      if (reason) {
        note(`own Vite server (${reason})`);
        return createServer(config);
      }
      const { id, port } = await hubCall<{ id: string; port: number }>(hub, "/vite", { config });
      return handle({ hub, id, port }) as Awaited<ReturnType<typeof createServer>>;
    };
    const fallback = (real as { default?: object }).default;
    mock.module("vite", () => ({
      ...real,
      createServer: shared,
      ...(fallback ? { default: { ...fallback, createServer: shared } } : {}),
    }));
  }

  if (share.has("browser")) {
    const playwright = await import("playwright");
    for (const engine of ["chromium", "webkit"] as const) {
      const type = playwright[engine] as unknown as {
        launch: (options?: unknown) => Promise<unknown>;
        connect: (wsEndpoint: string) => Promise<unknown>;
      };
      const launch = type.launch.bind(type);
      type.launch = async (options?: unknown) => {
        const reason = launchOwnReason(options);
        if (reason) {
          note(`own ${engine} (${reason})`);
          return launch(options);
        }
        const { wsEndpoint } = await hubCall<{ wsEndpoint: string }>(hub, "/browser", { engine, options: options ?? {} });
        return type.connect(wsEndpoint);
      };
    }
  }
}
