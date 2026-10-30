/** A gallery play's report as its stage publishes it (`window.cmuxGalleryPlayReport`, src/gallery/play.ts). */
type PlayReport = {
  status?: string;
  steps?: { step: string; status: string; problems: string[]; shifts?: { value: number; sources: string[] }[] }[];
  error?: string;
};

/** judgeStep's frame-timing and settle-latency problems (src/gallery/play.ts). */
const RUNNER_TIMING = [/^\d+ frame\(s\) over /, /^settle latency /];

/** What a layout shift moved, so a red names it: ` (moved: div.foo 0.00002, #text 0.00001)`. */
function shifted(shifts: { value: number; sources: string[] }[] | undefined): string {
  if (!shifts?.length) return "";
  return ` (moved: ${shifts.map((shift) => `${shift.sources.join(" + ") || "?"} ${shift.value.toPrecision(2)}`).join(", ")})`;
}

/**
 * What went wrong in a gallery play a behavior test drove, from its JSON report; empty when it did
 * what it drives. A play reports a step that went wrong (a missing target, a wait that never held,
 * the play's own check) as `error`, and the stage fails a step whose anchors moved or whose layout
 * shifted. It also fails a frame over 33 ms or a slow settle, which on the shared CI runner time the
 * runner as much as the page (cx-mfkky): those stay in the gallery report and do not fail a test.
 */
export function playFailures(report: string | undefined): string[] {
  const play = JSON.parse(report ?? "{}") as PlayReport;
  if (play.error) return [play.error];
  if (!play.status || play.status === "none" || !play.steps?.length) return [`the play ran no steps: ${report}`];
  return play.steps
    .filter((step) => step.status === "fail")
    .flatMap((step) =>
      step.problems
        .filter((problem) => !RUNNER_TIMING.some((timing) => timing.test(problem)))
        .map((problem) => `${step.step}: ${problem}${problem.startsWith("layout shift ") ? shifted(step.shifts) : ""}`),
    );
}
