// cmux-web-test-timeout: 480
// cmux-web-test-alone
// Part 10 of 12 of the accent and glass invariants over every web gallery stage
// (test/support/accentGlassInvariants.ts has the rules, the stages and why they are split).
// Its dev server is the gallery's: vite.config.gallery-dev.ts.
import { accentGlassInvariants } from "./support/accentGlassInvariants";

await accentGlassInvariants({
  file: "accent-glass-invariants-10.test.ts",
  part: 10,
  parts: 12,
  viteConfig: "vite.config.gallery-dev.ts",
});
