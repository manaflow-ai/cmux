// The one place a bench gets Playwright's browser types: import `chromium` and `webkit` from here, never from
// "playwright". Every Chromium launch then runs what the tests run (test/support/systemChrome.ts): the patched
// chrome-headless-shell at CMUX_CHROME_HEADLESS_SHELL for a headless launch when scripts/ci/ensure-system-chrome.sh
// fetched it, else the installed Google Chrome (channel "chrome"); a launch that names a channel or an executable
// keeps it. Playwright's own Chromium is never installed on the perf runner, so a bench that launched it failed
// with "Executable doesn't exist" (ui-stability on the perf cron, run 43326639123).
// test/bench-browser-launch.test.ts fails a bench file that imports a browser type from "playwright" directly.
//
// Every Chromium launch also starts its renderers with the V8 flags cmux's own Chromium starts them with
// (SHIPPED_JS_FLAGS), joined into the launch's own `--js-flags`: Chromium reads only the last `--js-flags`, so a
// bench's `--js-flags=--expose-gc` would otherwise drop them. Without them the benches measured a renderer cmux does
// not run: the god chat's thought p95 over a small chat's read 1.41x on the bench and 1.07x with the shipped flag.
/// <reference types="bun" />
import { chromium, webkit } from "playwright";
// Imported under a name without the `use` prefix: it is no React Hook, and React Doctor's rules-of-hooks reads a
// top-level `use…()` call as one.
import { useSystemChrome as launchSystemChrome } from "../test/support/systemChrome";

/// The V8 flags of every renderer cmux's Chromium starts: CEFSwitches.youngGeneration
/// (Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFSwitches.swift, cmux#47591), a 32 MB young generation
/// from the start. `BENCH_SHIPPED_JS_FLAGS=0` launches without them (an A/B of the flag itself).
export const SHIPPED_JS_FLAGS = ["--min-semi-space-size=32"];

type LaunchOptions = { args?: string[] };

/// OPTIONS with SHIPPED_JS_FLAGS joined into its one `--js-flags` argument (pure). A flag the launch already names
/// (any value) is the launch's: a bench that sets its own young generation keeps it.
export function withShippedJsFlags<T extends object = LaunchOptions>(
  options: T | undefined,
  flags = SHIPPED_JS_FLAGS,
): T & LaunchOptions {
  const args = (options as LaunchOptions | undefined)?.args ?? [];
  const own = args.filter((arg) => arg.startsWith("--js-flags=")).flatMap((arg) => arg.slice(11).split(/\s+/));
  const named = (flag: string) => own.some((f) => f.split("=")[0] === flag.split("=")[0]);
  const joined = [...own.filter(Boolean), ...flags.filter((flag) => !named(flag))];
  const rest = args.filter((arg) => !arg.startsWith("--js-flags="));
  return { ...options, args: joined.length ? [...rest, `--js-flags=${joined.join(" ")}`] : rest } as T & LaunchOptions;
}

function launchWithShippedJsFlags(env: Record<string, string | undefined> = process.env): void {
  if (env.BENCH_SHIPPED_JS_FLAGS === "0") return;
  const launch = chromium.launch.bind(chromium);
  const launchPersistentContext = chromium.launchPersistentContext.bind(chromium);
  const launchServer = chromium.launchServer.bind(chromium);
  chromium.launch = (options) => launch(withShippedJsFlags(options));
  chromium.launchPersistentContext = (dir, options) => launchPersistentContext(dir, withShippedJsFlags(options));
  chromium.launchServer = (options) => launchServer(withShippedJsFlags(options));
}

launchSystemChrome(chromium);
launchWithShippedJsFlags();

export { chromium, webkit };
