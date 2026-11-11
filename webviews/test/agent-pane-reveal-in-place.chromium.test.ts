// cmux-web-test-timeout: 600
// A chat shown again draws what came while it was away in place, in Chromium
// (agent-pane-reveal-in-place.shared.ts has the cases and why).
import { revealInPlace } from "./agent-pane-reveal-in-place.shared";

await revealInPlace("chromium");
