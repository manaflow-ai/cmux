// Scrolled up, the reader stays where they are until they ask for the latest row, in chromium:
// an input that is not the reader scrolling down, then a layout change to the end, or
// Find's End keys.
// test/support/transcriptScrolledUpStays.ts has the cases and why they are split.
import path from "node:path";
import { scrolledUpStays } from "./support/transcriptScrolledUpStays";

const webviews = path.resolve(import.meta.dir, "..");
await scrolledUpStays({
  file: "transcript-scrolled-up-stays-chromium-stays-browser.test.ts",
  engine: "chromium",
  cases: "stays",
  configFile: path.join(webviews, "vite.config.ts"),
});
