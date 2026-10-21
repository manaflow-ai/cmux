// The host shows a page once it reports its first frame (PagePaintProbe.swift): the pane keeps
// what it showed until then, 500 ms at most (PanePaintHold.limit). A page whose first screen needs
// data holds that report until the data is in, so the first frame the reader sees is final
// instead of "Loading…" and sections filling one by one. A pooled page holds the report the host
// asks for after its claim instead (`holdPaintUntil`, `holdPaintForClaim`).

/** The promise the probe waits for (PagePaintProbe.waitName). */
export const PAINT_AFTER_NAME = "__cmuxPaintAfter";

/** The page's own bound, under the host's: late data still lets the page report a frame. */
export const PAINT_AFTER_LIMIT_MS = 400;

/** Holds the first-frame report until `ready` settles or `limitMs` passes. Call it while the
    page's module runs: the probe is a document-end script and reads the promise once. */
export function holdFirstPaint(
  ready: Promise<unknown>,
  limitMs = PAINT_AFTER_LIMIT_MS,
  target: Record<string, unknown> = globalThis as unknown as Record<string, unknown>,
): Promise<void> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const limit = new Promise<void>((resolve) => (timer = setTimeout(resolve, limitMs)));
  const settled = ready.then(
    () => undefined,
    () => undefined,
  );
  const gate = Promise.race([settled, limit]).finally(() => clearTimeout(timer));
  target[PAINT_AFTER_NAME] = gate;
  return gate;
}

/** Where a pooled page leaves its first screen for the host's claim (`holdPaintUntil`). */
export const CLAIM_READY_NAME = "__cmuxPageClaimReady";

/**
 * Holds the paint report until the page's first screen is in. A parked (pooled) document is shown
 * only after the host claims it, and its calls wait for that claim: it leaves `firstScreen` for
 * `holdPaintForClaim`, which the claim runs, so the report the host asks for after the claim (the
 * pane's hold, PanePaintHold) comes once the claimed page has its data. Any other document holds
 * its first report now (`holdFirstPaint`). Settings drew every control disabled with its default
 * and grew cards for one or two hundred milliseconds after each open (Leo 2026-10-20).
 */
export function holdPaintUntil(
  firstScreen: () => Promise<unknown>,
  parked: boolean,
  target: Record<string, unknown> = globalThis as unknown as Record<string, unknown>,
): void {
  if (parked) target[CLAIM_READY_NAME] = firstScreen;
  else void holdFirstPaint(firstScreen(), PAINT_AFTER_LIMIT_MS, target);
}

/** The host claimed this parked document: the next paint report waits for its first screen. */
export function holdPaintForClaim(target: Record<string, unknown> = globalThis as unknown as Record<string, unknown>) {
  const firstScreen = target[CLAIM_READY_NAME];
  if (typeof firstScreen === "function")
    void holdFirstPaint((firstScreen as () => Promise<unknown>)(), PAINT_AFTER_LIMIT_MS, target);
}
