// cmux-web-test-timeout: 900
// The motion map's folds, streams and recap cases (the send cases are compound-motion.test.ts's; see
// there for the map). Two files keep each inside its time limit on a slow runner.
import type { CompoundCase } from "../src/agent-session/acpmux/conversation/compoundCases";
import { compoundMotionSuite, isSendCase } from "./support/compoundMotionSuite";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("compound-motion-folds.test.ts", () =>
  compoundMotionSuite("compound-motion-folds.test.ts", (scenario: CompoundCase) => !isSendCase(scenario)),
);
