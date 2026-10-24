// The queue's whole-row fit is a structural composer change: max-height should follow the same
// motion token as transcript folds instead of jumping the transcript by a row.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const css = readFileSync(new URL("../src/agent-session/acpmux/composerStates.css", import.meta.url), "utf8");

test("queued prompt growth transitions max-height on the structural motion token", () => {
  expect(css).toMatch(
    /@media \(prefers-reduced-motion: no-preference\)\s*\{\s*\.acpmux-composer-queue\s*\{\s*transition: max-height var\(--agent-motion-move\) var\(--agent-ease-out\);/,
  );
});
