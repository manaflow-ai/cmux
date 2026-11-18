// One Chromium shared by a pool of workers that walk many stages (gallery scans and audits).
//
// The class this guards: a test reuses one browser across hundreds of stages, and the browser dies or
// wedges partway (`newPage: Protocol error (Target.createBrowserContext): Failed to create browser
// context.`). Its `newPage` then rejects, or never answers, at every stage after. The worker threw out of
// its loop as an unhandled error, the other workers kept waiting on a dead browser, and the file ran to
// its 450 s limit, which the merge gate's webview verdict charged to whatever PR it ran on
// (accent-glass-invariants-3 on run 44139691454 and -5 on run 44105019567, 2026-11-17).
//
// Here every page open has a deadline. A failed or late open relaunches the browser (once for all the
// workers that saw the same browser fail) and retries the open once. When the relaunch budget is spent,
// every later open fails at once with `failure`, a message naming the cause, so the stages left end in
// milliseconds and the test fails on its own words, not on the file limit.
// Detector: test/stage-browser-recovery.test.ts (fake browsers; no Chromium needed).

/** The part of Playwright's `Browser` (and `Page`) this needs; fake ones in the unit test. */
export type Closable = { close(): Promise<void> };

export type StageBrowserOptions<B extends Closable, P extends Closable> = {
  /** Starts a browser: at first use and after a failed open. */
  launch: () => Promise<B>;
  /** Opens a stage's page on `browser` (for instance `browser.newPage({ viewport })`). */
  open: (browser: B) => Promise<P>;
  /** How long one open may take before the browser counts as wedged. */
  openTimeoutMs?: number;
  /** How long a launch may take. */
  launchTimeoutMs?: number;
  /** How long a close is awaited; a dead browser's close may never answer. */
  closeTimeoutMs?: number;
  /** Relaunches allowed over the whole file, so a browser that keeps dying ends the file early. */
  maxRelaunches?: number;
};

export class StageBrowserDead extends Error {
  override name = "StageBrowserDead";
}

const message = (error: unknown): string => String(error instanceof Error ? error.message : error).split("\n")[0]!;

/** Resolves `work`, or rejects with `what` past `ms`. A late result is handed to `late` (to close it). */
async function within<T>(work: Promise<T>, ms: number, what: string, late?: (value: T) => void): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  let timedOut = false;
  const deadline = new Promise<never>((_, reject) => {
    // fixed-wait: a deadline, not a wait; an open that answers clears it at once.
    timer = setTimeout(() => {
      timedOut = true;
      reject(new Error(`${what}: no answer in ${ms} ms`));
    }, ms);
  });
  work.then(
    (value) => {
      if (timedOut) late?.(value);
    },
    () => {},
  );
  try {
    return await Promise.race([work, deadline]);
  } finally {
    clearTimeout(timer);
  }
}

export type StageBrowser<B, P> = {
  /** The browser now in use (a later relaunch replaces it). */
  readonly browser: B;
  /** How many times the browser was relaunched. */
  readonly relaunches: number;
  /** Set once the browser could not be brought back; every later `page()` rejects with it at once. */
  readonly failure: string | undefined;
  /** A new page for the next stage: retried once on a relaunched browser, else a `StageBrowserDead`. */
  page(): Promise<P>;
  /** Closes a page without waiting past the close deadline (a hung page's close may never answer). */
  closePage(page: P): Promise<void>;
  /** Closes the browser, bounded the same way. */
  close(): Promise<void>;
};

export async function launchStageBrowser<B extends Closable, P extends Closable>(
  options: StageBrowserOptions<B, P>,
): Promise<StageBrowser<B, P>> {
  const openTimeoutMs = options.openTimeoutMs ?? 30_000;
  const launchTimeoutMs = options.launchTimeoutMs ?? 60_000;
  const closeTimeoutMs = options.closeTimeoutMs ?? 5_000;
  const maxRelaunches = options.maxRelaunches ?? 2;

  const bounded = (work: Promise<unknown>): Promise<void> =>
    within(work, closeTimeoutMs, "close").then(
      () => {},
      () => {},
    );
  const launch = () => within(options.launch(), launchTimeoutMs, "launch", (late) => void bounded(late.close()));

  let browser = await launch();
  let generation = 0;
  let relaunches = 0;
  let failure: string | undefined;
  // One relaunch for every worker that saw the same browser fail.
  let relaunching: Promise<void> | undefined;

  const relaunch = (failedGeneration: number, cause: string): Promise<void> => {
    if (failedGeneration !== generation) return Promise.resolve(); // another worker already replaced it
    if (relaunching) return relaunching;
    relaunching = (async () => {
      if (relaunches >= maxRelaunches) {
        failure ??= `the shared Chromium failed after ${relaunches} relaunch(es): ${cause}`;
        return;
      }
      relaunches++;
      const dead = browser;
      void bounded(dead.close());
      try {
        browser = await launch();
        generation++;
      } catch (error) {
        failure ??= `the shared Chromium could not be relaunched (${message(error)}) after: ${cause}`;
      }
    })().finally(() => {
      relaunching = undefined;
    });
    return relaunching;
  };

  const tryOpen = async (): Promise<{ page: P } | { generation: number; cause: string }> => {
    const used = generation;
    try {
      const page = await within(options.open(browser), openTimeoutMs, "newPage", (late) => void bounded(late.close()));
      return { page };
    } catch (error) {
      return { generation: used, cause: message(error) };
    }
  };

  return {
    get browser() {
      return browser;
    },
    get relaunches() {
      return relaunches;
    },
    get failure() {
      return failure;
    },
    async page() {
      if (failure) throw new StageBrowserDead(failure);
      if (relaunching) await relaunching;
      const first = await tryOpen();
      if ("page" in first) return first.page;
      await relaunch(first.generation, first.cause);
      if (failure) throw new StageBrowserDead(failure);
      const second = await tryOpen();
      if ("page" in second) return second.page;
      // The retry on the relaunched browser failed too: stop relaunching for this file.
      failure ??= `the shared Chromium could not open a page after a relaunch: ${second.cause} (first: ${first.cause})`;
      throw new StageBrowserDead(failure);
    },
    closePage(page) {
      return bounded(page.close());
    },
    close() {
      return bounded(browser.close());
    },
  };
}
