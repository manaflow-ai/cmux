// cmux-web-test-timeout: 480
// Part 3 of 4 of the control-surface audit over every web gallery entry
// (test/support/galleryControlSurfaces.ts has the rules, the cases and why they are split).
import { galleryControlSurfaces } from "../support/galleryControlSurfaces";

await galleryControlSurfaces({ file: "gallery-control-surfaces-3.test.ts", part: 3, parts: 4 });
