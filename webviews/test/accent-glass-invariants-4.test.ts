// cmux-web-test-timeout: 480
// Part 4 of 4 of the accent and glass invariants over every web gallery stage
// (test/support/accentGlassInvariants.ts has the rules, the stages and why they are split).
// Its dev server is the gallery's: vite.config.gallery-dev.ts.
import { accentGlassInvariants } from "./support/accentGlassInvariants";

await accentGlassInvariants({
  file: "accent-glass-invariants-4.test.ts",
  part: 4,
  parts: 4,
  viteConfig: "vite.config.gallery-dev.ts",
});
