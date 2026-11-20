// cmux-web-test-timeout: 600
// cmux-web-test-alone
// Part 17 of 24 of the control contrast audit over every web gallery entry in every theme and mode
// (test/support/controlContrast.ts has the rules, the schemes and why it is split).
// Its dev server is the gallery's: vite.config.gallery-dev.ts.
import { controlContrast } from "./support/controlContrast";

await controlContrast({
  file: "control-contrast-17.test.ts",
  part: 17,
  parts: 24,
  viteConfig: "vite.config.gallery-dev.ts",
});
