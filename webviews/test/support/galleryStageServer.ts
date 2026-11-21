// The server the gallery scans load their stages from (accent-glass-invariants, control-contrast,
// gallery-control-surfaces): a production build of the gallery when the runner made one, else
// today's Vite dev server.
//
// Why a build: on the dev server each stage is a page load of about 650 unbundled modules, about 330
// of them revalidated, all served by one Vite thread (95% of a core). 80 stages at 8 workers took
// 22.5 s on 16 cores, 29.3 s pinned to 4 and 59.8 s pinned to 2, against 6.5 s and 15.4 s from the
// built gallery (2026-11-21, a 16-core lane VM). The react-apps-check shards moved to the 4 vCPU pool,
// at times 2 vCPU (ci-web.yml, 2026-11-18), and the parts went from about 280 s to past their limits
// at the same per-stage code. The dev server also failed loads under that load ("Failed to fetch
// dynamically imported module": 17 of 264 loads, none from the build), stages the scans then skipped.
//
// accent-glass-invariants-1 took 297 s on the dev server and 55 s on the build (85 s pinned to 4 cores),
// control-contrast-1 417 s and 110 s, with the same findings on every stage both read; the build read
// every stage (603 of 603, 453 of 453) where the dev server dropped 26 and 19.
//
// scripts/ci/run-webviews-tests.sh builds the gallery once per run (`CMUX_GALLERY_STAGE_CSS=dev bun run
// gallery:build`: the dev server's CSS, which the baselines were read from, not the shipped minified CSS)
// and names the folder in CMUX_GALLERY_STAGE_BUILD; a folder without frame.html, or none, keeps the dev server.
import fs from "node:fs";
import path from "node:path";
import { warmGalleryFrame } from "./galleryFrame";

export type GalleryStageServer = {
  /** `http://127.0.0.1:<port>`. */
  origin: string;
  /** The stage page's path on `origin`: `/frame.html` on the build, `/gallery/frame.html` on the dev server. */
  framePath: string;
  /** Whether stages come from the production build. */
  built: boolean;
  close(): Promise<void>;
};

export type GalleryStageServerOptions = {
  /** The dev server's config file (absolute), used when there is no build. */
  configFile: string;
  /** The dev server's root, when it is not the config's. */
  root?: string;
  /** Warms the dev server once it listens (no build only); given the server, as warmGalleryFrame takes it. */
  warm?: (server: Parameters<typeof warmGalleryFrame>[0]) => Promise<unknown>;
  /** The build folder; CMUX_GALLERY_STAGE_BUILD by default. */
  build?: string;
};

/** The build folder to serve, when `dir` holds a built gallery (its frame.html). */
export function galleryBuildDir(dir: string | undefined = process.env.CMUX_GALLERY_STAGE_BUILD): string | undefined {
  return dir && fs.existsSync(path.join(dir, "frame.html")) ? path.resolve(dir) : undefined;
}

/** Serves `dir` on loopback: its files with their content types, 404 for anything else or outside it. */
export function serveGalleryBuild(dir: string): GalleryStageServer {
  const root = path.resolve(dir);
  const server = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    async fetch(request) {
      let pathname: string;
      try {
        pathname = decodeURIComponent(new URL(request.url).pathname);
      } catch {
        return new Response("bad path", { status: 400 });
      }
      const file = path.join(root, pathname === "/" ? "index.html" : pathname);
      if (file !== root && !file.startsWith(root + path.sep)) return new Response("not found", { status: 404 });
      const body = Bun.file(file);
      if (!(await body.exists())) return new Response("not found", { status: 404 });
      // The build never changes during a run: chunks are cached by each page, so a stage after the
      // first loads only what it has not loaded yet. Pages stay uncached (each stage's query differs anyway).
      return new Response(body, file.endsWith(".html") ? {} : { headers: { "cache-control": "max-age=3600" } });
    },
  });
  return {
    origin: `http://127.0.0.1:${server.port}`,
    framePath: "/frame.html",
    built: true,
    close: async () => {
      await server.stop(true);
    },
  };
}

/** The scans' stage server: the build when there is one, else a Vite dev server, warmed by `warm`. */
export async function galleryStageServer({
  configFile,
  root,
  warm,
  build = process.env.CMUX_GALLERY_STAGE_BUILD,
}: GalleryStageServerOptions): Promise<GalleryStageServer> {
  const dir = galleryBuildDir(build);
  if (dir) return serveGalleryBuild(dir);
  const { createServer } = await import("vite");
  const vite = await createServer({
    ...(root ? { root } : {}),
    configFile,
    server: { port: 0, host: "127.0.0.1", strictPort: false },
    logLevel: "error",
  });
  await vite.listen();
  const server: GalleryStageServer = {
    origin: `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`,
    framePath: "/gallery/frame.html",
    built: false,
    close: () => vite.close(),
  };
  try {
    await warm?.(vite);
  } catch (error) {
    await vite.close();
    throw error;
  }
  return server;
}
