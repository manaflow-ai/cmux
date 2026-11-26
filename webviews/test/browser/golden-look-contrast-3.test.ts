// cmux-web-test-timeout: 600
// A quarter of the golden screen's looks (support/goldenLookContrastSuite.ts): about 100 stages at 3.7 s
// on the CI runner (2026-11-23), where the whole list (405 stages) ran past the 900 s cap.
import { goldenLookContrastSuite } from "../support/goldenLookContrastSuite";
import { requireBrowserLane } from "../support/requireBrowserLane";

await requireBrowserLane("golden-look-contrast-3.test.ts", () => goldenLookContrastSuite(3, 4));
