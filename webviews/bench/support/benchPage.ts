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
import type { Frame, Page } from "playwright";
import { build, createServer } from "vite";
import { warmViteServer } from "../../test/support/warmDevServer";
import { SHARED_BUILD_DONE, SHARED_BUILD_ENV, sharedPageKey } from "./sharedBuilds";

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
  /// Keep names in the build (`minify: false`). A bench that reads a profile's function names needs
  /// it: a build is minified by default, and a minified chunk profiles as mangled identifiers at
  /// line 1, which tells a reader nothing.
  unminified?: boolean;
}

/// Whether this run asked for the dev server. A bench passes it to `serveBenchPage` and uses it to
/// label its output; `--dev` is the only way to get one.
export function devRequested(argv: readonly string[] = process.argv): boolean {
  return argv.includes("--dev");
}

/// A run's positional arguments, with the flags taken out. `--dev` is a flag every bench accepts,
/// so a bench reading `process.argv[2]` directly turned `bun bench/x.bench.ts --dev` into its row
/// count and threw `usage:` before `--dev` could mean anything.
export function benchPositionals(argv: readonly string[] = process.argv.slice(2)): string[] {
  return argv.filter((arg) => !arg.startsWith("-"));
}

/// What a page's build emitted: the page's HTML and every file, by its name under the build's directory.
export interface BuiltPage {
  emitted: string;
  files: string[];
}

/// The manifest a page's build leaves in its directory, so a shared build (bench/support/prebuild.ts) is served
/// from exactly the files it emitted.
const BUILT_PAGE_MANIFEST = "bench-page.json";

function readBuiltPage(dir: string): BuiltPage | undefined {
  try {
    const got = JSON.parse(fs.readFileSync(path.join(dir, BUILT_PAGE_MANIFEST), "utf8")) as BuiltPage;
    return typeof got.emitted === "string" && Array.isArray(got.files) ? got : undefined;
  } catch {
    return undefined;
  }
}

/// Builds `pagePath` with `config` into `outDir` (a production build) and says what it emitted.
export async function buildBenchPage(
  pagePath: string,
  { config = "vite.config.ts", unminified = false }: Pick<BenchPageOptions, "config" | "unminified">,
  outDir: string,
): Promise<BuiltPage> {
  const configFile = path.join(webviews, config);
  const built = await build({
    root: webviews,
    configFile,
    mode: "production",
    logLevel: "error",
    build: {
      outDir,
      emptyOutDir: true,
      ...(unminified ? { minify: false } : {}),
      // A config with its own page (the agent pane's `vite.config.acpmux-pane.mjs`) keeps it; only a
      // page this bench names by path is passed as the input. Both input keys are set: the tree's
      // own `vite.config.ts` drives Rolldown and reads `rolldownOptions`, so overriding
      // `rollupOptions` alone built the config's pages instead and served the first HTML it emitted
      // (the diff viewer's), which installs none of a harness's hooks and read as a 30 s
      // `waitForFunction` timeout.
      ...(pagePath === "/"
        ? {}
        : {
            rollupOptions: { input: path.join(webviews, pagePath.slice(1)) },
            rolldownOptions: { input: path.join(webviews, pagePath.slice(1)) },
          }),
    } as never,
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
  // Segment-aligned, so `other-transcript-fling.html` is not read as this page, and unique, so an
  // `index.html` emitted twice is an error rather than a coin toss.
  const pages = html.filter((name) => name === wanted || name.endsWith(`/${wanted}`));
  const emitted = pages.length === 1 ? pages[0] : undefined;
  // Never another page: the build emitting HTML that is not the one asked for means the input did
  // not take, and serving it would measure a page that installs no hooks.
  if (!emitted)
    throw new Error(
      `serveBenchPage: the build of ${pagePath} emitted ${pages.length === 0 ? "no" : `${pages.length}`} ${wanted}` +
        ` (it emitted ${html.join(", ") || "no HTML"})`,
    );
  // Every file the build wrote, by its name under `outDir`. The server answers out of this list and
  // nothing else, so no request can reach a file the build did not emit.
  const files = [
    ...new Set(
      outputs
        .flatMap((one) => one.output ?? [])
        .map((asset) => asset.fileName)
        .filter((name): name is string => typeof name === "string"),
    ),
  ];
  fs.writeFileSync(path.join(outDir, BUILT_PAGE_MANIFEST), JSON.stringify({ emitted, files }));
  return { emitted, files };
}

/// Serves `pagePath` (a path under `webviews/`, as the page's URL, e.g.
/// "/test/browser/transcript-fling.html"). A build by default; a dev server with `dev: true`.
///
/// The build is per page and goes to a temporary `outDir` of its own, so two benches never race for
/// one. It is a cold build every run (the directory is new, and `close` removes it), so a production
/// bench pays a build before it measures anything; what it measures is the page after load, as the
/// dev path does. Under bench/web-ui-suite.ts the page is the suite's one shared build of it instead
/// (CMUX_BENCH_PAGES_DIR, bench/support/sharedBuilds.ts), kept for the run's other users.
export async function serveBenchPage(
  pagePath: string,
  { dev = devRequested(), config = "vite.config.ts", query = "", unminified = false }: BenchPageOptions = {},
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
    await warmViteServer(server, `${pagePath}${query}`);
    const { port } = server.httpServer!.address() as { port: number };
    return { url: `http://127.0.0.1:${port}${pagePath}${query}`, dev: true, close: () => server.close() };
  }
  // Built to a temporary directory and served statically, as the benches that already measure a
  // build do (bench/chat-100k-flat.bench.ts and its neighbours), unless bench/web-ui-suite.ts built
  // this page once for its run already (bench/support/sharedBuilds.ts): the same build, outside
  // this bench's timeout.
  // The pages directory holds one directory per page, each with its own done marker.
  const shared = unminified ? undefined : process.env[SHARED_BUILD_ENV.pages];
  const sharedDir = shared && path.join(shared, sharedPageKey(config, pagePath));
  const prebuilt =
    sharedDir && fs.existsSync(path.join(sharedDir, SHARED_BUILD_DONE)) ? readBuiltPage(sharedDir) : undefined;
  const outDir = prebuilt ? sharedDir! : fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "bench-page-"));
  const { emitted, files } = prebuilt ?? (await buildBenchPage(pagePath, { config, unminified }, outDir));
  const emittedFiles = new Set(files);
  // The tree's build emits chunks and assets at the output root (`chunks/x.mjs`, `assets/x.css`)
  // while a plugin rewrites the page's script URLs to be relative to the page, so a page emitted
  // under a directory of its own (`test/browser/transcript-fling.html`) asks for
  // `test/browser/chunks/x.mjs`. That reading is served too, but only when exactly one emitted file
  // ends in the asked path's segments: an ambiguous suffix (two `index.html`, two same-named chunks)
  // is a 404, never a guess, because answering with the wrong file of the same name is the silent
  // failure this helper exists to stop. Without this the page loaded, installed no hooks, and read
  // as a 30 s `waitForFunction` timeout behind five 404s.
  const resolveEmitted = (asked: string): string | undefined => {
    if (emittedFiles.has(asked)) return asked;
    const parts = asked.split("/");
    for (let drop = 1; drop < parts.length; drop += 1) {
      const tail = parts.slice(drop).join("/");
      const matches = [...emittedFiles].filter((name) => name === tail || name.endsWith(`/${tail}`));
      if (matches.length === 1) return matches[0];
      if (matches.length > 1) return undefined;
    }
    return undefined;
  };
  // The page is served at the root, as the app serves its pages. The build writes the page's own
  // `<link>`s relative to it (`./assets/x.css`) while a lazy chunk's preload asks for its CSS from
  // the root (`/assets/x.css`); under `test/browser/` those are two URLs, so the preload added every
  // sheet a second time and each restyle matched the whole stylesheet twice (17,092 rules for
  // 8,546): the transcript fling's forced row measures read about 30% slower than the app's.
  const servedAt = path.basename(emitted);
  const statics = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    async fetch(request) {
      // Decoded, so an emitted name with a space or a non-ASCII character is reachable; `pathname`
      // has already resolved any dot segments, and a `%2f` inside a segment stays inside it.
      let pathname = new URL(request.url).pathname;
      try {
        pathname = decodeURIComponent(pathname);
      } catch {
        // A malformed escape is read as itself.
      }
      const asked = pathname === "/" ? "index.html" : pathname.replace(/^\/+/, "");
      const found = asked === servedAt ? emitted : resolveEmitted(asked);
      if (found === undefined) return new Response("not found", { status: 404 });
      return new Response(Bun.file(path.join(outDir, found)));
    },
  });
  return {
    url: `http://127.0.0.1:${statics.port}/${servedAt}${query}`,
    dev: false,
    close: async () => {
      await statics.stop(true);
      if (!prebuilt) fs.rmSync(outDir, { recursive: true, force: true });
    },
  };
}

/// Loads a served bench page, refusing a response that is not the page. A 404 from a build whose
/// HTML landed elsewhere otherwise shows up as a timeout waiting for hooks the page never installed.
export async function gotoBenchPage(page: Page, served: BenchPage): Promise<void> {
  // A page that throws while it mounts installs none of its hooks, and the bench then fails 30 s
  // later as `waitForFunction: Timeout` with nothing to point at. So every page error and console
  // error is printed as it happens.
  watchPageErrors(page);
  // Before the page's own code: the recorder has to see react-dom's request, and the pane clears the
  // resource list as it goes.
  await installReactWatch(page);
  const response = await page.goto(served.url);
  const status = response?.status();
  if (status !== undefined && status >= 400)
    throw new Error(`gotoBenchPage: ${served.url} answered ${status}; the ${buildLabel(served)} page is not there`);
}

/// What the page's react-dom says about itself. Each of these is read out of the code the page
/// actually fetched, not from a bundler's flags, so neither a dev server's module URLs nor a
/// build's asset names can make this say the wrong thing.
///
/// Three of the four are string literals, which a minifier cannot rename; the development marker is
/// an identifier, so a *renamed* development bundle falls through to "react-dom seen, no production
/// marker", which reads as `unknown` and is refused like a dev bundle. The verdict is never
/// "production" because nothing was found.
const REACT_MARKERS = {
  /// `react-dom-client.development.js` and `react-dom-profiling.development.js` define it; no other
  /// bundle has the name. It is one of the three commit-phase instrumentation functions this whole
  /// change is about.
  development: "addObjectDiffToProperties",
  /// The production and profiling bundles carry the minified-error text; the development bundle
  /// spells its errors out instead and never contains this.
  production: "Minified React error",
  /// The profiling and development bundles have the profiler's own state; the production bundle does
  /// not. A profiling build keeps instrumentation a user does not pay for, so it is not a production
  /// number either.
  profiling: "isProfiling",
  /// The key react-dom writes its root onto. Every build has it, so this is how the page says
  /// "react-dom is here at all" — without it there is nothing to judge and the answer is `unknown`.
  reactDom: "__reactContainer$",
} as const;

/// Which react-dom the page loaded. `unknown` means no react-dom could be read (nothing fetched,
/// every script cross-origin or 404, or a bundle whose markers are gone): a run then says it could
/// not tell, and is refused unless `--dev` was asked for.
export type ReactBuild = "development" | "profiling" | "production" | "unknown";

/// How long to wait for react-dom to turn up. The pane loads it in a lazy chunk, so a page asked
/// right after `goto` has fetched the entry and the runtime and not yet react-dom: reading once gave
/// "no react-dom" for a production page that was about to load one. So the scripts are re-read until
/// react-dom appears.
const REACT_WAIT_MS = 10_000;

/// Reads every same-origin script the page fetched and says which react-dom build it holds. Only a
/// response the page could actually read counts: a 404 body is not evidence of anything, which is
/// what made an earlier version of this call a missing chunk "production". Each script is read once;
/// new ones are picked up until react-dom is found or the wait runs out.
export async function reactBuildOfPage(page: Page, waitMs: number = REACT_WAIT_MS): Promise<ReactBuild> {
  // `CMUX_BENCH_REACT_DEBUG=1` prints every script this read and which markers it carried: when the
  // answer is `unknown` that list is the only way to tell "nothing was fetched" from "react-dom is
  // there and its markers moved".
  if (process.env.CMUX_BENCH_REACT_DEBUG === "1")
    for (const line of await reactScriptReport(page)) console.log(`bench react: ${line}`);
  return page.evaluate(
    async ([markers, wait]: [Record<string, string>, number]) => {
      const here = location.origin;
      const seen = { development: false, production: false, profiling: false, reactDom: false };
      const done = new Set<string>();
      const deadline = Date.now() + wait;
      for (;;) {
        const recorded = (window as unknown as { __benchScripts?: string[] }).__benchScripts;
        const urls = [
          ...(recorded ?? []),
          ...performance.getEntriesByType("resource").map((entry) => entry.name),
        ].filter((name) => name.startsWith(here) && /\.[cm]?js(\?|$)/.test(name) && !done.has(name));
        // react-dom's own module first (a dev server serves it as one), then everything else: a build
        // inlines it into a chunk whose name says nothing.
        urls.sort((a, b) => Number(/react-dom/i.test(b)) - Number(/react-dom/i.test(a)));
        for (const url of urls) {
          done.add(url);
          let text: string;
          try {
            const response = await fetch(url);
            if (!response.ok) continue;
            text = await response.text();
          } catch {
            // A module the page can no longer fetch says nothing either way.
            continue;
          }
          for (const [which, marker] of Object.entries(markers))
            if (text.includes(marker)) seen[which as keyof typeof seen] = true;
          if (seen.development) break;
        }
        if (seen.development) return "development" as const;
        if (seen.reactDom || seen.production) break;
        if (Date.now() >= deadline) break;
        await new Promise((resume) => setTimeout(resume, 150));
      }
      if (seen.production) return seen.profiling ? ("profiling" as const) : ("production" as const);
      return "unknown" as const;
    },
    [REACT_MARKERS as unknown as Record<string, string>, waitMs] as [Record<string, string>, number],
  );
}

/// Records every script the page fetches, before any of the page's own code runs.
///
/// Reading `performance.getEntriesByType("resource")` at check time is not enough: the pane's perf
/// budgets call `performance.clearResourceTimings()`, so by then the list held 40 stylesheets and no
/// react-dom at all, and the check said "no react-dom on this page" for a page that had loaded one.
/// A `PerformanceObserver` installed before the page's first script sees every entry as it happens,
/// and nothing later can clear what it has already written down.
export async function installReactWatch(page: Page): Promise<void> {
  await page.addInitScript(() => {
    const seen: string[] = [];
    (window as unknown as { __benchScripts: string[] }).__benchScripts = seen;
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) seen.push(entry.name);
    }).observe({ type: "resource", buffered: true });
  });
}

/// Every same-origin script the page fetched, with the markers each carried: the diagnostic behind
/// `CMUX_BENCH_REACT_DEBUG=1`.
async function reactScriptReport(page: Page): Promise<string[]> {
  return page.evaluate(
    async (markers: Record<string, string>) => {
      const here = location.origin;
      const rows: string[] = [];
      const recorded = (window as unknown as { __benchScripts?: string[] }).__benchScripts;
      const every = new Set([
        ...(recorded ?? []),
        ...performance.getEntriesByType("resource").map((entry) => entry.name),
      ]);
      for (const url of [...every].filter((name) => name.startsWith(here))) {
        try {
          const response = await fetch(url);
          const text = response.ok ? await response.text() : "";
          const carries = Object.entries(markers)
            .filter(([, marker]) => text.includes(marker))
            .map(([which]) => which);
          rows.push(`${url.slice(here.length)} ${response.status} ${text.length}B ${carries.join(",") || "-"}`);
        } catch (error) {
          rows.push(`${url.slice(here.length)} unread ${String(error)}`);
        }
      }
      return rows;
    },
    REACT_MARKERS as unknown as Record<string, string>,
  );
}

/// Refuses to let a run print a number it cannot say is the code a user runs.
///
/// A `dev` run is allowed anything and keeps its label. Otherwise only `production` passes: a
/// development bundle costs about a third of a frame in instrumentation, a profiling one keeps
/// instrumentation of its own, and `unknown` means the page could not be read, which is a broken
/// harness. Throwing is the point — a number from any of the three would read as a production
/// number and nothing downstream could tell.
///
/// Returns what it found, so a caller can print it.
export async function requireProductionReact(page: Page, { dev }: { dev: boolean }): Promise<ReactBuild> {
  const build = await reactBuildOfPage(page);
  if (dev) {
    if (build === "production") console.warn("bench: --dev was given but the page loaded a production React bundle");
    return build;
  }
  if (build === "production") return build;
  const why = {
    development:
      "the page loaded React's development bundle, whose commit-phase instrumentation was ~1/3 of a frame when" +
      " this was measured",
    profiling: "the page loaded React's profiling bundle, which keeps instrumentation a user does not pay for",
    unknown:
      "no react-dom could be read from the page (nothing fetched, every script 404 or cross-origin, or a bundle" +
      " whose markers are gone), so this number cannot be called a production number",
  }[build];
  throw new Error(
    `bench: ${why} (bench/support/benchPage.ts). Serve the build, or pass --dev to take a dev number knowingly.`,
  );
}

/// How a bench labels its numbers: `dev` when they came from a dev server, `production` otherwise.
export function buildLabel({ dev }: { dev: boolean }): "dev" | "production" {
  return dev ? "dev" : "production";
}

/// Every page error and error-level console message the page has produced since this was called, in
/// order, newest last. A bench that waits for a hook the page installs needs them: a page that threw
/// while it mounted installs nothing, and the wait then fails as `waitForFunction: Timeout` with
/// `log: []` and nothing to point at (2026-11-23: both arms of a composer-typing before/after run
/// died that way, and the run reported no measurement at all).
export function watchPageErrors(page: Page): string[] {
  const errors: string[] = [];
  page.on("pageerror", (error) => {
    errors.push(`page error: ${error.message}`);
    console.error(`bench page error: ${error.message}`);
  });
  page.on("console", (message) => {
    if (message.type() !== "error") return;
    errors.push(`console: ${message.text()}`);
    console.error(`bench page console: ${message.text()}`);
  });
  return errors;
}

/// Waits for the page to install `hook` on `window` and, when it does not, says what the page held
/// instead: the errors it threw (`watchPageErrors`, when its list is given), its title, whether the
/// React root has any children, and the start of its text. A 404 served as a body, a page that threw
/// while mounting and a pane that mounted but installed nothing read identically through a bare
/// `waitForFunction`; each of them is a different fix.
export async function waitForPageHook(
  surface: Page | Frame,
  hook: string,
  { timeout = 60_000, errors }: { timeout?: number; errors?: string[] } = {},
): Promise<void> {
  try {
    await surface.waitForFunction((name) => name in window, hook, { timeout });
  } catch (cause) {
    const held = await surface
      .evaluate(() => {
        const root = document.querySelector("#root, [id*='root']");
        return {
          url: location.href,
          title: document.title,
          rootChildren: root ? root.childElementCount : -1,
          text: (document.body?.innerText ?? "").slice(0, 200).replace(/\s+/g, " ").trim(),
          hooks: Object.keys(window).filter((key) => key.startsWith("cmux")),
        };
      })
      .catch((error: unknown) => ({ error: String(error) }));
    const said = errors?.length ? ` The page's errors: ${errors.join(" | ")}.` : " The page threw nothing.";
    throw new Error(
      `bench: the page never installed window.${hook} within ${timeout} ms, so nothing could be measured.` +
        `${said} What it held instead: ${JSON.stringify(held)}` +
        " (bench/support/benchPage.ts waitForPageHook).",
      { cause },
    );
  }
}
