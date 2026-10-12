/** A gallery play's report as its stage publishes it (`window.cmuxGalleryPlayReport`, src/gallery/play.ts). */
type PlayReport = { status?: string; steps?: { step: string; problems?: string[] }[]; error?: string };

/**
 * What went wrong in a gallery play a behavior test drove, from its JSON report; empty when it did
 * what it drives.
 */
export function playFailures(report: string | undefined): string[] {
  const play = JSON.parse(report ?? "{}") as PlayReport;
  if (play.status === "pass") return [];
  return [
    play.error ?? `play ${play.status ?? "missing"}`,
    ...(play.steps ?? []).flatMap((step) => (step.problems ?? []).map((problem) => `${step.step}: ${problem}`)),
  ];
}
