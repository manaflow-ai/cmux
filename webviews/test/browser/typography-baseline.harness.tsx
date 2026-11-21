// l10n-allow-file: harness fixtures.
// The lines that put a ticking clock (ui/Typography.tsx `Clock`) in their words, drawn with the
// pane's own CSS: the host's waiting line with its quiet Restart agent service, the restoring line,
// and the fork line with its time and Cancel. typography-baseline-browser.test.ts measures them.
import { createRoot } from "react-dom/client";
import { HostRecoveringLine, HostWaitingLine } from "../../src/agent-session/acpmux/HostError";
import { ForkPendingLine } from "../../src/agent-session/acpmux/ForkPendingLine";
import "../../src/pages/shared/desktop.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";

function Harness() {
  return (
    <div className="acpmux-shell" style={{ display: "grid", width: 640 }}>
      <div data-testid="waiting">
        <HostWaitingLine since={0} now={67_000} onRestart={() => undefined} />
      </div>
      <div data-testid="restoring">
        <HostRecoveringLine restoring={{ waitedMs: 12_000, at: 0 }} now={3_000} />
      </div>
      <div data-testid="fork">
        <ForkPendingLine since={0} now={67_000} onCancel={() => undefined} />
      </div>
    </div>
  );
}

createRoot(document.getElementById("root")!).render(<Harness />);
requestAnimationFrame(() => requestAnimationFrame(() => (document.documentElement.dataset.harnessReady = "true")));
