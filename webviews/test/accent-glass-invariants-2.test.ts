// cmux-web-test-timeout: 480
// Part 2 of 7 of the accent and glass invariants over every web gallery stage
// (test/support/accentGlassInvariants.ts has the rules, the stages and why they are split).
// Its dev server is the gallery's: vite.config.gallery-dev.ts.
import { accentGlassInvariants } from "./support/accentGlassInvariants";

await accentGlassInvariants({
  file: "accent-glass-invariants-2.test.ts",
  part: 2,
  parts: 7,
  viteConfig: "vite.config.gallery-dev.ts",
});
