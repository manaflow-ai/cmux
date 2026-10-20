// The host shows a page once it reports its first frame (PagePaintProbe.swift): the pane keeps
// what it showed until then, 500 ms at most (PanePaintHold.limit). A page whose first screen needs
// data holds that report until the data is in, so the first frame the reader sees is final
// instead of "Loading…" and sections filling one by one. Not for a pooled page: a parked document
// cannot load before its claim.

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
