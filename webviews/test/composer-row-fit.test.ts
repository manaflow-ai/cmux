// The controls row's steps (composerRowFit.ts, the compact-composer verdict) must settle: each step
// change resizes the row and runs the check again, so a row resized across a boundary by a
// fraction of a pixel must not flip every frame. A pane's width sets the least step it takes.
import { describe, expect, test } from "bun:test";
import { fitForms, fitStep, ROW_FIT_STEPS } from "../src/agent-session/acpmux/composerRowFit";

describe("composer row fit", () => {
  const room = 400;
  const last = ROW_FIT_STEPS.length;
  // The widths the row takes at each step, 40 px less a step.
  const widths = (base: number) => (step: number) => base - 40 * step;

  test("a row too long for its width takes the fewest extra steps that fit", () => {
    expect(fitStep(0, widths(room), room)).toBe(0);
    expect(fitStep(0, widths(room + 1), room)).toBe(1);
    expect(fitStep(0, widths(room + 0.4), room)).toBe(0);
    expect(fitStep(0, widths(room + 1000), room)).toBe(last);
  });

  test("a lower step comes back only with clear room", () => {
    expect(fitStep(1, widths(room - 1), room)).toBe(1);
    expect(fitStep(1, widths(room - 8), room)).toBe(0);
  });

  test("the composer's width shortens labels first and drops controls last; the mic stays", () => {
    const at = (width: number) => fitForms(width);
    expect(at(760)).toEqual({ access: "full", effort: "full", harness: "full", mic: "full", model: "full" });
    expect(at(470)).toEqual({ access: "full", effort: "short", harness: "full", mic: "full", model: "full" });
    expect(at(460)).toEqual({ access: "full", effort: "short", harness: "icon", mic: "full", model: "full" });
    expect(at(440)).toEqual({ access: "full", effort: "short", harness: "icon", mic: "full", model: "family" });
    expect(at(420)).toEqual({ access: "icon", effort: "short", harness: "icon", mic: "full", model: "family" });
    expect(at(371)).toEqual({ access: "icon", effort: "short", harness: "icon", mic: "full", model: "family" });
    expect(at(370)).toEqual({ access: "icon", effort: "short", harness: "icon", mic: "full", model: "icon" });
    expect(at(340)).toEqual({ access: "icon", effort: "short", harness: "icon", mic: "full", model: "icon" });
    expect(at(240)).toEqual({ access: "icon", effort: "short", harness: "icon", mic: "full", model: "icon" });
  });

  test("a row too long for its width gives up the model's name last and never the mic", () => {
    expect(fitForms(760, ROW_FIT_STEPS.length - 1).model).toBe("family");
    expect(fitForms(760, ROW_FIT_STEPS.length)).toMatchObject({ model: "icon", mic: "full" });
    expect(fitForms(760, ROW_FIT_STEPS.length + 4).mic).toBe("full");
  });
});
