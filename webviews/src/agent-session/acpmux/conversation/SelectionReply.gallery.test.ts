// l10n-allow-file: test fixtures.
// The selection-reply gallery entry's experiment script runs on every variant: the compare view
// replays it on whichever stage is open. A stage without the long reply (chip-above) has no line to
// select to its right edge, so the step must keep that stage's own selection, not wait for the long
// reply until its wait times out.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import entry from "./SelectionReply.gallery";
import type { PlayContext } from "../../../gallery/play";

test("the wrap experiment's step finishes on a stage without the long reply", async () => {
  const dom = new JSDOM(
    `<!doctype html><body><div data-row-id="gallery-reply-answer"><div class="cv-md"><p>I'd retry only on 429 and 503.</p></div></div></body>`,
  );
  const ctx = {
    document: dom.window.document,
    // The stage has painted: a wait that does not hold now never will.
    waitFor: async (condition: () => unknown) => {
      if (!condition()) throw new Error("waitFor did not hold");
    },
  } as unknown as PlayContext;
  const experiment = entry.experiment!;
  for (const step of experiment.script) await step.run(ctx);
  expect(dom.window.document.querySelector('[data-row-id="gallery-reply-long"]')).toBeNull();
  dom.window.close();
});
