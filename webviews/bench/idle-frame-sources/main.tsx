// l10n-allow-file: bench fixture, not shipped UI.
// The page bench/idle-frame-sources.bench.ts measures: the agent pane's always-on page parts that can draw while
// nothing changes, on the pane's own stylesheets: the flicker detector (its batches go nowhere), the page-key
// mark, the Chief dock with its mascot, and one label whose text changes once a second (a minute label or a
// presence row: the DOM change a chat at rest still gets).
import "../../src/agent-session/acpmux/mount";
import { createRoot } from "react-dom/client";
import { ChiefDock } from "../../src/agent-session/acpmux/ChiefDock";
import { startFlickerLog } from "../../src/agent-session/acpmux/flickerLog";
import { installPageKey } from "../../src/agent-session/acpmux/pageKey";
import { session } from "../../src/gallery/fixtures/acpmux";

installPageKey(document);
const batches: unknown[] = [];
(window as unknown as { __flickerBatches: unknown[] }).__flickerBatches = batches;
startFlickerLog(window, (events) => void batches.push(events));

const sessions = [
  session({ sessionId: "a", title: "Prepare the release notes", status: "idle", updatedAt: 1000 }),
  session({ sessionId: "b", title: "Review the sidebar polish", status: "idle", updatedAt: 900 }),
];
const root = document.getElementById("root")!;
createRoot(root).render(
  <div className="acpmux-shell" style={{ height: "100vh" }}>
    <span id="minute-label">0 s</span>
    <ChiefDock
      sessions={sessions}
      currentId="a"
      defaultExpanded={false}
      onSelect={() => undefined}
      onNewChat={() => undefined}
      onMoveToTab={() => undefined}
    />
  </div>,
);

// The label ticks once a second, as the bench asks (`?tick=0` keeps it still).
if (new URLSearchParams(location.search).get("tick") !== "0") {
  let seconds = 0;
  // Looked up at each tick: React renders the label after this module runs.
  setInterval(() => {
    const label = document.getElementById("minute-label");
    if (label) label.textContent = `${++seconds} s`;
  }, 1000);
}
