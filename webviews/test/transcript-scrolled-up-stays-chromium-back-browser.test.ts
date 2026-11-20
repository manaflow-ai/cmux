// Scrolled up, the reader stays where they are until they ask for the latest row, in chromium:
// the explicit ways back, and wheels over a tool's output.
// test/support/transcriptScrolledUpStays.ts has the cases and why they are split.
import path from "node:path";
import { scrolledUpStays } from "./support/transcriptScrolledUpStays";

const webviews = path.resolve(import.meta.dir, "..");
await scrolledUpStays({
  file: "transcript-scrolled-up-stays-chromium-back-browser.test.ts",
  engine: "chromium",
  cases: "back",
  configFile: path.join(webviews, "vite.config.ts"),
});
