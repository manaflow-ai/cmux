// cmux-web-test-timeout: 600
// cmux-web-test-alone
// Part 8 of 12 of every layout-shift case in the agent chat (test/support/layoutEveryCase.ts has the gate,
// the cases it plays and why they are split). Leo, 2026-11-22: "EVERY POSSIBLE CASE, NO MATTER HOW WILD".
import { layoutEveryCase } from "./support/layoutEveryCase";

await layoutEveryCase({ file: "layout-every-case-browser-8.test.ts", part: 8 });
