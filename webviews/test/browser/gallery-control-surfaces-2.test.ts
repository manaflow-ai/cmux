// cmux-web-test-timeout: 480
// Part 2 of 4 of the control-surface audit over every web gallery entry
// (test/support/galleryControlSurfaces.ts has the rules, the cases and why they are split).
import { galleryControlSurfaces } from "../support/galleryControlSurfaces";

await galleryControlSurfaces({ file: "gallery-control-surfaces-2.test.ts", part: 2, parts: 4 });
