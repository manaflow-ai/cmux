// l10n-allow-file: benchmark output, not shipped UI.
// The builds bench/web-ui-suite.ts makes once per run and hands to its benches, so no bench's timeout pays for one.
//
// Each browser bench used to build its page cold inside its own timeout: the agent pane (vite.config.acpmux-pane.mjs)
// six times a suite run, the transcript fling page and the whole gallery once each. On a small Linux pool runner
// (perf cron run 45457645242, 2026-11-24) the pane build alone took 81 s, about 7x a 16-core host's 12 s, so the
// builds ate the timeouts and seven benches were killed with SIGKILL (exit 137, "timed out after N s") before they
// measured anything; the part was incomplete and stored no row. The host-contention probe read 1 throughout: the
// runner was not busy, it had fewer cores, and a build is the multi-threaded step that shows it.
//
// The suite builds each shared build with `bench/support/prebuild.ts KIND OUT` and names the directory to the benches
// that use it in the variable below. A bench takes the directory only when it would build the same thing (no
// PROFILE, no unminified build); otherwise, or when the variable is unset (a bench run alone), it builds its own.
/// <reference types="bun" />
import fs from "node:fs";
import path from "node:path";

/// The kinds of shared build and the variable each is handed in.
export const SHARED_BUILD_ENV = {
  /// The agent pane's production build (vite.config.acpmux-pane.mjs), as each pane bench builds it.
  pane: "CMUX_BENCH_PANE_DIR",
  /// The static gallery (vite.config.gallery.ts after gen-strings), as bench/ui-stability.bench.ts builds it.
  gallery: "CMUX_BENCH_GALLERY_DIR",
  /// A directory of serveBenchPage builds, one per page (bench/support/benchPage.ts sharedPageDir).
  pages: "CMUX_BENCH_PAGES_DIR",
} as const;
export type SharedBuildKind = keyof typeof SHARED_BUILD_ENV;

/// The file a finished build writes last into its directory, so a directory a killed build left half-written is
/// never taken.
export const SHARED_BUILD_DONE = ".shared-build-done";

/// The suite's finished build of KIND, or undefined (unset, or the build did not finish).
export function sharedBuildDir(kind: SharedBuildKind, env: NodeJS.ProcessEnv = process.env): string | undefined {
  const dir = env[SHARED_BUILD_ENV[kind]];
  return dir && fs.existsSync(path.join(dir, SHARED_BUILD_DONE)) ? path.resolve(dir) : undefined;
}

/// The suite's finished agent pane build, or undefined.
export function sharedPaneDir(env: NodeJS.ProcessEnv = process.env): string | undefined {
  return sharedBuildDir("pane", env);
}

/// The directory name of a page's build under the pages directory (pure): the config and the page path, each
/// character outside [A-Za-z0-9.-] an underscore.
export function sharedPageKey(config: string, pagePath: string): string {
  return `${config}__${pagePath}`.replace(/[^A-Za-z0-9.-]/g, "_");
}

/// Marks DIR as a finished build of the suite.
export function markSharedBuildDone(dir: string): void {
  fs.writeFileSync(path.join(dir, SHARED_BUILD_DONE), "");
}
