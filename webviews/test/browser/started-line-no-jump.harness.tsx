// l10n-allow-file: synthetic subagent names, not shipped UI.
// A turn's "started working" line as a second subagent joins it (started-line-no-jump-browser.test.ts):
// the line is drawn with one subagent, then with two, in a row of a set width, as the pane draws it
// when parallel Agent calls of one message start a moment apart. Every name here is synthetic.
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import "../../src/pages/shared/desktop.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";
import "../../src/agent-session/acpmux/subagents/subagents.css";
import { SubagentStartedLine } from "../../src/agent-session/acpmux/subagents/SubagentStartedLine";
import { SubagentNavContext } from "../../src/agent-session/acpmux/subagents/subagentGroupModel";
import { SUBAGENT_STARTED } from "../../src/agent-session/acpmux/subagents/subagentRows";
import type { Subagent } from "../../src/agent-session/acpmux/subagents/subagentFold";
import strings from "../../src/agent-session/acpmux/generated/strings.json";
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";

globalThis.__cmuxPaneStrings = { en: strings.en };
document.documentElement.dataset.cmuxMotion = "off";
for (const [key, value] of Object.entries({
  "--agent-page-bg": "#202124",
  "--agent-text": "#f5f5f1",
  "--agent-muted": "#c9c9c4",
  "--agent-soft": "#95958f",
  "--font-ui": "system-ui",
}))
  document.documentElement.style.setProperty(key, value);
document.documentElement.style.colorScheme = "dark";
document.body.style.background = "#202124";
document.body.style.margin = "0";

const agent = (id: string, name: string, startedAt: number): Subagent => ({
  id,
  parent: null,
  name,
  task: name,
  state: "running",
  startedAt,
});
const AGENTS = [
  agent("chat/toolu_a", "Unfuck sidebar group layout when collapsed groups reorder", 1_000),
  agent("chat/toolu_b", "Analyze Lucas's Claude bottleneck on the long session", 1_400),
  agent("chat/toolu_c", "Check the third thing nobody asked about", 1_600),
];
const line = (count: number): AcpmuxRow => ({
  id: `${SUBAGENT_STARTED}:group`,
  kind: SUBAGENT_STARTED,
  at: 1_000,
  version: count,
  subagents: AGENTS.slice(0, count),
  startedNamed: count,
});

const host = document.getElementById("root")!;
host.style.padding = "16px";
const root = createRoot(host);
const show = (count: number, width: number) =>
  flushSync(() =>
    root.render(
      <SubagentNavContext.Provider value={() => {}}>
        <div data-testid="row" style={{ width: `${width}px` }}>
          {count > 0 && <SubagentStartedLine row={line(count)} />}
        </div>
      </SubagentNavContext.Provider>,
    ),
  );
(window as unknown as { show: typeof show }).show = show;
show(0, 640);
document.documentElement.dataset.harnessReady = "true";
