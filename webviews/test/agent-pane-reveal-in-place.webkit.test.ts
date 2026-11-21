// cmux-web-test-timeout: 600
// A chat shown again draws what came while it was away in place, in WebKit
// (agent-pane-reveal-in-place.shared.ts has the cases and why).
import path from "node:path";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { revealInPlace } from "./agent-pane-reveal-in-place.shared";

const webviews = path.resolve(import.meta.dir, "..");
await requireBrowserLane("agent-pane-reveal-in-place.webkit.test.ts", () =>
  revealInPlace("webkit", path.join(webviews, "vite.config.acpmux-pane.mjs")),
);
