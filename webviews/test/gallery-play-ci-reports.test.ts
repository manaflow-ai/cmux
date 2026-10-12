// A play test passes when the play did what it drives, whatever the CI runner's timing graded
// (cx-mfkky). react-apps-check failed a different play test from run to run on measures of the
// runner: a frame over 33 ms, a layout shift of 0.006 as late layout landed inside a step, a menu
// still fading out from its own click graded as a covered popup. Each passed locally and on the
// next run. The gallery matrix gates those measures (src/gallery/ENTRIES.md); a play test judges
// its play through test/support/galleryPlay.ts.
//
// The reports below are the ones CI printed for those failures, trimmed to the graded fields.
import { describe, expect, test } from "bun:test";
import { playFailures } from "./support/galleryPlay";

/** Plays that did what they drive while the runner's timing failed their grade. */
const runnerGraded = {
  "instructions-notice": {
    status: "fail",
    steps: [
      {
        step: 'click button "Chat actions"',
        action: "click",
        layoutShift: 0,
        longFrames: [91.60000000003492],
        frameSource: "long-animation-frame",
        status: "fail",
        problems: ["1 frame(s) over 33 ms (longest 91.6 ms)"],
      },
      {
        step: 'click menuitem "Edit CLAUDE.md"',
        action: "click",
        layoutShift: 0,
        longFrames: [],
        frameSource: "long-animation-frame",
        status: "pass",
        problems: [],
      },
      {
        step: "click .acpmux-instructions-notice button:not([data-notice-action])",
        action: "click",
        layoutShift: 0,
        longFrames: [],
        frameSource: "long-animation-frame",
        status: "pass",
        problems: [],
      },
      {
        step: 'click .acpmux-instructions-notice button[data-notice-action="dismiss"]',
        action: "click",
        layoutShift: 0,
        longFrames: [],
        frameSource: "long-animation-frame",
        status: "pass",
        problems: [],
      },
    ],
  },
  "worktree-creating": {
    status: "warn",
    steps: [
      {
        step: 'click [aria-label="Folder"]',
        action: "click",
        layoutShift: 0,
        longFrames: [],
        frameSource: "long-animation-frame",
        status: "pass",
        problems: [],
      },
      {
        step: 'click menuitem "New Worktree"',
        action: "click",
        layoutShift: 0.0005005255738029284,
        longFrames: [],
        frameSource: "long-animation-frame",
        status: "warn",
        problems: [
          "popup div.ui-popup is covered at top-left by output.acpmux-switch-notice (z-index or portal)",
          "popup div.ui-popup is covered at top-right by output.acpmux-switch-notice (z-index or portal)",
          "popup div.ui-popup is covered at bottom-left by div.acpmux-composer-bar (z-index or portal)",
          "popup div.ui-popup is covered at bottom-right by div.acpmux-composer-bar (z-index or portal)",
          "popup div.ui-popup is covered at center by div.acpmux-md-field (z-index or portal)",
        ],
      },
    ],
  },
  "chat-palette-actions": {
    status: "fail",
    steps: [
      {
        step: "focus [contenteditable='true']",
        action: "focus",
        layoutShift: 0.005770429362880886,
        longFrames: [],
        frameSource: "long-animation-frame",
        status: "fail",
        problems: ["layout shift 0.0058 (limit 0)"],
      },
    ],
  },
};

describe("a gallery play's CI report", () => {
  for (const [name, report] of Object.entries(runnerGraded))
    test(`${name}: a play graded on the runner's timing has no failures`, () => {
      expect(playFailures(JSON.stringify(report))).toEqual([]);
    });

  test("a play whose step found no element fails with the play's error", () => {
    // secret-card's report from the same runs: the card had not drawn its field.
    const report = { status: "fail", steps: [], error: "play: no element for .acpmux-secret-card-field" };
    expect(playFailures(JSON.stringify(report))).toEqual(["play: no element for .acpmux-secret-card-field"]);
  });
});
