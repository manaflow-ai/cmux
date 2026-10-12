/** A gallery play's report as its stage publishes it (`window.cmuxGalleryPlayReport`, src/gallery/play.ts). */
type PlayReport = { status?: string; steps?: unknown[]; error?: string };

/**
 * What went wrong in a gallery play a behavior test drove, from its JSON report; empty when it did
 * what it drives. A play reports a step that went wrong (a missing target, a wait that never held,
 * the play's own check) as `error`. Its status also grades frame timing, layout shift, settle
 * latency and popup layers, which on a shared CI runner measure the runner as much as the page:
 * the gallery matrix gates those (src/gallery/ENTRIES.md), not a behavior test (cx-mfkky).
 */
export function playFailures(report: string | undefined): string[] {
  const play = JSON.parse(report ?? "{}") as PlayReport;
  if (play.error) return [play.error];
  if (!play.status || play.status === "none" || !play.steps?.length) return [`the play ran no steps: ${report}`];
  return [];
}
