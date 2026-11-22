// cmux-web-test-timeout: 900
// The motion map (Leo, 2026-11-22: "when i send it collapses the compser then sends it to you... but
// i think we should be able to calculate it out to be like one smooth motion. there are a lot of
// these possible compound movement situations, esp with folds, that i think we can watch for and map
// out harder to have more cohesive animations."). The page (browser/compound-motion.harness.tsx)
// draws the real transcript and plays one compound case at a time; Chromium draws one frame every
// 8.33 ms on the frames' own clock (support/frames120.ts, browser/frameClock.ts), so a loaded host
// draws the same frames. Each case runs RUNS times on both arms of compound-motion (the transaction,
// and each mover on its own as before); the map prints the median run's phases: frames, px a frame,
// and the anchor's (the row under the viewport's middle) net move and travel.
// This file runs the send cases; compound-motion-folds.test.ts runs the folds, streams and recap.
import { compoundMotionSuite, isSendCase } from "./support/compoundMotionSuite";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("compound-motion.test.ts", () => compoundMotionSuite("compound-motion.test.ts", isSendCase));
