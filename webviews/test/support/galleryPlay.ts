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
 *
 * `steps` "all" also takes the problems of a step the stage only warned about (a popup that is
 * covered, clipped or past the viewport, where the entry does not ask for the popup-layer check):
 * for a test whose play opens no menu that fades out under its own click.
 */
export function playFailures(report: string | undefined, steps: "failed" | "all" = "failed"): string[] {
  const play = JSON.parse(report ?? "{}") as PlayReport;
  if (play.error) return [play.error];
  if (!play.status || play.status === "none" || !play.steps?.length) return [`the play ran no steps: ${report}`];
  return play.steps
    .filter((step) => steps === "all" || step.status === "fail")
    .flatMap((step) =>
      step.problems
        .filter((problem) => !RUNNER_TIMING.some((timing) => timing.test(problem)))
        .map((problem) => `${step.step}: ${problem}${problem.startsWith("layout shift ") ? shifted(step.shifts) : ""}`),
    );
}

/**
 * One workflow notice line that names everything the stage graded, the runner's timing too, or
 * undefined when the play passed. A test prints it and the runner keeps a passing file's notices
 * (scripts/ci/run-webviews-tests.sh), so a green run on a slow runner still says which step it was:
 * `::notice title=<name> play::status fail; step 1 of 2, click button "Stop": 1 frame(s) over 33 ms (longest 63.8 ms)`.
 */
export function playNotice(name: string, report: string | undefined): string | undefined {
  const play = JSON.parse(report ?? "{}") as PlayReport;
  if (play.status === "pass") return undefined;
  const steps = play.steps ?? [];
  const problems = steps.flatMap((step, index) =>
    step.problems.map((problem) => `step ${index + 1} of ${steps.length}, ${step.step}: ${problem}`),
  );
  const said = [play.error, ...problems].filter(Boolean).join("; ") || `no problem named: ${report}`;
  return `::notice title=${name} play::status ${play.status ?? "none"}; ${said.replace(/\s+/g, " ")}`;
}
