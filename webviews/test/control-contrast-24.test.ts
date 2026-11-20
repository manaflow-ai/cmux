// cmux-web-test-timeout: 600
// cmux-web-test-alone
// Part 24 of 24 of the control contrast audit over every web gallery entry in every theme and mode
// (test/support/controlContrast.ts has the rules, the schemes and why it is split).
// Its dev server is the gallery's: vite.config.gallery-dev.ts.
import { controlContrast } from "./support/controlContrast";

await controlContrast({
  file: "control-contrast-24.test.ts",
  part: 24,
  parts: 24,
  viteConfig: "vite.config.gallery-dev.ts",
});
