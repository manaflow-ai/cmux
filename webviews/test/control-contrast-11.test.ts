// cmux-web-test-timeout: 900
// cmux-web-test-alone
// Part 11 of 12 of the control contrast audit over every web gallery entry in every theme and mode
// (test/support/controlContrast.ts has the rules, the schemes and why it is split).
// Its dev server is the gallery's: vite.config.gallery-dev.ts.
import { controlContrast } from "./support/controlContrast";

await controlContrast({
  file: "control-contrast-11.test.ts",
  part: 11,
  parts: 12,
  viteConfig: "vite.config.gallery-dev.ts",
});
