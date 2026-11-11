// cmux-web-test-timeout: 660
// Part 4 of 4 of the control-surface audit over every web gallery entry
// (test/support/galleryControlSurfaces.ts has the rules and why it is split).
import { galleryControlSurfaces } from "../support/galleryControlSurfaces";
import { requireBrowserLane } from "../support/requireBrowserLane";

await requireBrowserLane("gallery-control-surfaces-4.test.ts", () => galleryControlSurfaces({ part: 4, parts: 4 }));
