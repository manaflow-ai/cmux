// cmux-web-test-timeout: 480
// Part 8 of 8 of the control-surface audit over every web gallery entry
// (test/support/galleryControlSurfaces.ts has the rules, the cases and why they are split).
import { galleryControlSurfaces } from "../support/galleryControlSurfaces";
import { requireBrowserLane } from "../support/requireBrowserLane";

await requireBrowserLane("gallery-control-surfaces-8.test.ts", () => galleryControlSurfaces({ part: 8, parts: 8 }));
