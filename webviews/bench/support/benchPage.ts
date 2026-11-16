// Where a bench gets its page, and the one check that keeps a number honest.
//
// Every bench here used to serve its page from a Vite dev server, so the page ran react-dom's
// **development** bundle. A CDP sampling profile of the transcript resize drag at 100k rows
// (2026-11-16) put about a third of main-thread self time in three functions of it:
// `addObjectDiffToProperties` (14.2%), `addObjectToProperties` (10.8%) and `addValueToProperties`
// (6.9%), React's commit-phase Performance-track instrumentation, which diffs the props of every
// component whose props changed on every commit. None of those functions exists in react-dom's
// production bundle, so that third of each frame reaches no user, and it lands hardest exactly
// where our benches look: a transcript committing many rows with object props.
//
// So a bench serves a **build** by default, and a dev server only when it is asked for `--dev`,
// where every number it prints is labelled `dev`. `requireProductionReact` refuses to let a run
// print a number from a development bundle otherwise, so this cannot come back quietly.
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { Page } from "playwright";
import { build, createServer } from "vite";
import { warmViteServer } from "../../test/support/warmDevServer";

const webviews = path.resolve(import.meta.dir, "..", "..");

/// A served bench page: the URL to load, whether React is the development build, and how to stop
/// serving it.
export interface BenchPage {
  /// The page's whole URL. A build emits its HTML under a name of its own choosing, so this is read
  /// from what the build wrote and never guessed from the source path.
  url: string;
  /// A dev server serves it (so `--dev` was asked for): every number from it is a dev number.
  dev: boolean;
  close: () => Promise<void>;
}

/// How a bench asks for its page.
export interface BenchPageOptions {
  /// Serve a dev server instead of a build (`--dev`): every number is then a dev number.
  dev?: boolean;
  /// The Vite config, relative to `webviews/`. The default builds the tree's pages; the agent
  /// pane's own entry point is `vite.config.acpmux-pane.mjs`, whose page is its config's own, so
  /// such a bench passes `"/"` as its page path.
  config?: string;
  /// Appended to the URL (`"?mock"`): the mock daemon the pane's page reads.
  query?: string;
}

/// Whether this run asked for the dev server. A bench passes it to `serveBenchPage` and uses it to
/// label its output; `--dev` is the only way to get one.
export function devRequested(argv: readonly string[] = process.argv): boolean {
  return argv.includes("--dev");
}

/// Serves `pagePath` (a path under `webviews/`, as the page's URL, e.g.
/// "/test/browser/transcript-fling.html"). A build by default; a dev server with `dev: true`.
///
/// The build is per page and goes to its own `outDir`, so two benches never race for one, and it is
/// not emptied between runs of the same page: Vite skips what has not changed, which is what keeps a
/// production bench's start comparable to the dev server's warm start.
export async function serveBenchPage(
  pagePath: string,
  { dev = devRequested(), config = "vite.config.ts", query = "" }: BenchPageOptions = {},
): Promise<BenchPage> {
  const configFile = path.join(webviews, config);
  if (dev) {
    const server = await createServer({
      root: webviews,
      configFile,
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    await warmViteServer(server, pagePath);
    const { port } = server.httpServer!.address() as { port: number };
    return { url: `http://127.0.0.1:${port}${pagePath}${query}`, dev: true, close: () => server.close() };
  }
  // Built to a temporary directory and served statically, as the benches that already measure a
  // build do (bench/chat-100k-flat.bench.ts and its neighbours).
  const outDir = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "bench-page-"));
  const built = await build({
    root: webviews,
    configFile,
    mode: "production",
    logLevel: "error",
    build: {
      outDir,
      emptyOutDir: true,
      // A config with its own page (the agent pane's `vite.config.acpmux-pane.mjs`) keeps it; only a
      // page this bench names by path is passed as the input.
      ...(pagePath === "/" ? {} : { rollupOptions: { input: path.join(webviews, pagePath.slice(1)) } }),
    },
  });
  // Where the build put the page. Vite names an emitted HTML file itself (an input outside the root's
  // usual pages, a flattening plugin), so asking for the source path can 404 and read as a page that
  // never installed its hooks: a 30 s `waitForFunction` timeout with nothing to point at.
  const outputs = (Array.isArray(built) ? built : [built]) as Array<{ output?: Array<{ fileName?: string }> }>;
  const html = outputs
    .flatMap((one) => one.output ?? [])
    .map((asset) => asset.fileName)
    .filter((name): name is string => typeof name === "string" && name.endsWith(".html"));
  const wanted = pagePath === "/" ? "index.html" : path.basename(pagePath);
  const emitted = html.find((name) => name.endsWith(wanted)) ?? html[0];
  if (!emitted) throw new Error(`serveBenchPage: the build of ${pagePath} emitted no HTML`);
  const statics = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    async fetch(request) {
      const pathname = new URL(request.url).pathname;
      const file = Bun.file(path.join(outDir, pathname === "/" ? "index.html" : pathname));
      if (!(await file.exists())) return new Response("not found", { status: 404 });
      return new Response(file);
    },
  });
  return {
    url: `http://127.0.0.1:${statics.port}/${emitted}${query}`,
    dev: false,
    close: async () => {
      await statics.stop(true);
      fs.rmSync(outDir, { recursive: true, force: true });
    },
  };
}

/// Loads a served bench page, refusing a response that is not the page. A 404 from a build whose
/// HTML landed elsewhere otherwise shows up as a timeout waiting for hooks the page never installed.
export async function gotoBenchPage(page: Page, served: BenchPage): Promise<void> {
  const response = await page.goto(served.url);
  const status = response?.status();
  if (status !== undefined && status >= 400)
    throw new Error(`gotoBenchPage: ${served.url} answered ${status}; the ${buildLabel(served)} page is not there`);
}

/// A function react-dom defines in its development bundle alone (`react-dom-client.development.js`,
/// `react-dom-profiling.development.js`): its production bundle has no such name. Read from the code
/// the page actually loaded, not from the bundler's own flags, so neither a dev server's module URLs
/// nor a build's asset names can make this say the wrong thing.
const DEVELOPMENT_ONLY_REACT = "addObjectDiffToProperties";

/// Whether the React the page loaded is a development bundle. Reads every same-origin script the
/// page fetched, newest first for a dev server's own react-dom module, and looks for a name only the
/// development build has. `undefined` when no script could be read (an offline page, a cross-origin
/// one): a run then says it could not tell rather than claiming either.
export async function reactIsDevelopmentBuild(page: Page): Promise<boolean | undefined> {
  return page.evaluate(async (marker: string) => {
    const here = location.origin;
    const urls = performance
      .getEntriesByType("resource")
      .map((entry) => entry.name)
      .filter((name) => name.startsWith(here) && /\.[cm]?js(\?|$)/.test(name));
    // react-dom's own module first (a dev server serves it as one), then everything else: a build
    // inlines it into a chunk whose name says nothing.
    urls.sort((a, b) => Number(/react-dom/i.test(b)) - Number(/react-dom/i.test(a)));
    let read = 0;
    for (const url of urls) {
      try {
        const text = await (await fetch(url)).text();
        read += 1;
        if (text.includes(marker)) return true;
      } catch {
        // A module the page can no longer fetch says nothing either way.
      }
    }
    return read === 0 ? undefined : false;
  }, DEVELOPMENT_ONLY_REACT);
}

/// Refuses to let a run print a number taken from React's development bundle.
///
/// `dev` runs are allowed and keep their label; a run that did not ask for `--dev` and still got a
/// development bundle is a broken harness, and throwing is the point: a number from it would be a
/// third slower than what a user pays, and nothing downstream could tell.
export async function requireProductionReact(page: Page, { dev }: { dev: boolean }): Promise<void> {
  const development = await reactIsDevelopmentBuild(page);
  if (development === undefined) {
    console.warn("bench: could not tell which React bundle the page loaded; treating the number as unlabelled");
    return;
  }
  if (development && !dev)
    throw new Error(
      "bench: the page loaded React's development bundle, whose commit-phase instrumentation was ~1/3 of a" +
        " frame when this was measured (bench/support/benchPage.ts). Serve the build, or pass --dev to take a" +
        " dev number knowingly.",
    );
  if (!development && dev) console.warn("bench: --dev was given but the page loaded a production React bundle");
}

/// How a bench labels its numbers: `dev` when they came from a dev server, `production` otherwise.
export function buildLabel({ dev }: { dev: boolean }): "dev" | "production" {
  return dev ? "dev" : "production";
}
