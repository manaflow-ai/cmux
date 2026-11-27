// l10n-allow-file: isolated browser fixture.
// Load the same sizing and typography tokens as the app before the pane styles.
import "../../src/pages/shared/desktop.css";
import { createRoot } from "react-dom/client";
import { TimeBreakdown, type TimeBreakdownLook } from "../../src/agent-session/acpmux/session-info/TimeBreakdown";
import { breakdown } from "../../src/agent-session/acpmux/session-info/TimeBreakdown.gallery";
import strings from "../../src/agent-session/acpmux/generated/strings.json";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";

globalThis.__cmuxPaneStrings = strings;
const look = (new URLSearchParams(location.search).get("look") ?? "stacked") as TimeBreakdownLook;
const spans = Array.from({ length: 60 }, (_, index) => ({
  turnSeq: index + 1,
  turnId: `turn-${index + 1}`,
  category: index % 2 ? "run" : "read",
  startAt: index * 100,
  endAt: (index + 1) * 100,
  turnTokens: 10,
}));
createRoot(document.getElementById("root")!).render(
  <div className="acpmux-shell" style={{ padding: 16, minWidth: 0 }}>
    <TimeBreakdown
      breakdown={{ ...breakdown, spans, tokensComplete: false }}
      look={look}
      onShowTurn={(id) => document.body.setAttribute("data-revealed-turn", id)}
    />
  </div>,
);
