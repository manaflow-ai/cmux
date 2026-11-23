// l10n-allow-file: harness fixture commands, not shipped UI.
// The tray of running work above the composer (subagents/SubagentTray.tsx) as the chat's bottom
// stack lays it out (bottomStack.css), with the pane's stylesheets in its bundle's order
// (scripts/cmux-next/build-agent-pane-web.sh). The test draws one background command, one that opens its output and one with
// nothing to open (`window.__showTray`).
import { createRoot } from "react-dom/client";
import { setPaneLanguage } from "../../src/agent-session/acpmux/i18n";
import { SubagentTray } from "../../src/agent-session/acpmux/subagents/SubagentTray";
import { finishedTrayItems, trayItems } from "../../src/agent-session/acpmux/subagents/runningTray";
import "../../src/pages/shared/desktop.css";
import "../../src/ui/glass/glass.css";
import "../../src/ui/popupSurface.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/composerControls.css";
import "../../src/agent-session/acpmux/composerStates.css";
import "../../src/agent-session/acpmux/composerLocation.css";
import "../../src/agent-session/acpmux/bottomStack.css";
import "../../src/agent-session/acpmux/summary/summary.css";
import "../../src/agent-session/acpmux/subagents/subagents.css";
import "../../src/agent-session/acpmux/session-info/sessionInfo.css";

globalThis.__cmuxPaneStrings ??= (await import("../../src/agent-session/acpmux/generated/strings.json")).default;
setPaneLanguage("en");

const root = document.getElementById("root")!;
document.body.style.margin = "0";
// A dark theme's tokens, as the host sends them.
Object.assign(document.documentElement.style, { background: "#1b1b1b" });
for (const [name, value] of Object.entries({
  "--agent-text": "#e8e8e8",
  "--agent-muted": "#9a9a9a",
  "--agent-accent": "#8ab4f8",
  "--agent-page-bg": "#1b1b1b",
  "--cv-inset": "16px",
}))
  document.documentElement.style.setProperty(name, value);

const view = createRoot(root);
const command = "cd /Users/you/fun/cmux-wt/chromium-transparency && RED=cb8f4178187d46d5; GREEN=1 bun test";
(window as unknown as { __showTray: (clickable: boolean) => void }).__showTray = (clickable) => {
  const items = trayItems(
    [],
    [
      {
        id: "s/1",
        command,
        state: "running",
        processId: "s/1",
        toolCallId: "call-1",
        startedAt: Date.now() - 3_508_000,
      },
    ],
    [],
    true,
  );
  view.render(
    <section className="acpmux-shell" style={{ width: 720 }}>
      <div className="acpmux-main">
        <div className="acpmux-dock">
          <SubagentTray
            items={items}
            working
            waiting={new Set()}
            onOpen={() => {}}
            onOpenCommand={clickable ? () => {} : undefined}
            stopProcess={async () => {}}
          />
        </div>
      </div>
    </section>,
  );
};
// The same command with its tail open as a host that reads output and opens terminals shows it
// (`window.__showOpenCommand`): the command, then one line of its time, state and Open in terminal.
(window as unknown as { __showOpenCommand: (width?: number, line?: string) => void }).__showOpenCommand = (
  width = 720,
  line = command,
) => {
  const items = trayItems(
    [],
    [
      {
        id: "s/1",
        command: line,
        state: "running",
        processId: "s/1",
        toolCallId: "call-1",
        startedAt: Date.now() - 33_000,
      },
    ],
    [],
    true,
  );
  view.render(
    <section className="acpmux-shell" style={{ width }}>
      <div className="acpmux-main">
        <div className="acpmux-dock">
          <SubagentTray
            items={items}
            working
            waiting={new Set()}
            onOpen={() => {}}
            onOpenCommand={() => {}}
            canReadTail
            stopProcess={async () => {}}
          />
        </div>
      </div>
    </section>,
  );
};
// Leo's panel (2026-10-25) at 118 agents: 2 running, 116 ended, in a dock `height` tall that
// squeezes the tray as a short pane does.
(window as unknown as { __showPanel: (height: number) => void }).__showPanel = (height) => {
  const now = Date.now();
  const agents = [
    ...[0, 1].map((index) => ({
      id: `run-${index}`,
      parent: null,
      name: `Run ${index}`,
      state: "running",
      startedAt: now - 60_000 + index,
    })),
    ...Array.from({ length: 116 }, (_, index) => ({
      id: `done-${index}`,
      parent: null,
      name: `Done ${index}`,
      state: "completed",
      startedAt: now - 90_000,
      endedAt: now - 80_000 + index,
    })),
  ];
  view.render(
    <section className="acpmux-shell" style={{ width: 720 }}>
      <div className="acpmux-main" data-dock="float">
        <div className="acpmux-dock" style={{ display: "flex", flexDirection: "column", height, overflow: "hidden" }}>
          <SubagentTray
            items={trayItems(agents, [], [], true)}
            finished={finishedTrayItems(agents, [])}
            working
            waiting={new Set()}
            onOpen={() => {}}
          />
        </div>
      </div>
    </section>,
  );
};
// Leo's hat (2026-11-07): a running subagent with a long task, a finished one, and a running command
// whose shell line runs long (`window.__showRows`). What a line's click calls is kept in
// `window.__opened`, so a test can tell a line that expands in place from one that navigates.
const opened: string[] = [];
(window as unknown as { __opened: string[] }).__opened = opened;
(window as unknown as { __showRows: (width?: number) => void }).__showRows = (width = 720) => {
  const now = Date.now();
  const agents = [
    {
      id: "long",
      parent: null,
      name: "Reviewer",
      task: "Audit every background task row in the composer hat for clipped titles and misaligned trailing columns",
      state: "running",
      startedAt: now - 374_000,
    },
    {
      id: "done",
      parent: null,
      name: "Tester",
      task: "Run the tray tests",
      state: "completed",
      startedAt: now - 90_000,
      endedAt: now - 54_000,
    },
  ];
  const wait = "glaeda-gh wait file ~/Projects/checkouts/cmux/composer-hat-row-check/.done --timeout 3600";
  view.render(
    <section className="acpmux-shell" style={{ width }}>
      <div className="acpmux-main">
        <div className="acpmux-dock">
          <SubagentTray
            items={trayItems(
              agents,
              [
                {
                  id: "w/1",
                  command: wait,
                  state: "running",
                  processId: "w/1",
                  toolCallId: "call-w",
                  startedAt: now - 60_000,
                },
              ],
              [],
              true,
            )}
            finished={finishedTrayItems(agents, [])}
            working
            waiting={new Set()}
            onOpen={(id) => opened.push(`agent:${id}`)}
            onOpenCommand={(entry) => opened.push(`command:${entry.id}`)}
            stop={async () => {}}
            stopProcess={async () => {}}
          />
        </div>
      </div>
    </section>,
  );
};
// A subagent's command (Leo, 2026-11-07: "me clicking this, the entire box, it just feels like, okay, I
// would be expanding this"): its title names the subagent, and a click anywhere on the line, the title
// included, expands it; the way to the subagent is the detail's Open chat. `terminal` says whether the
// host opens terminals; where it does not, the detail shows no Open in terminal
// (`window.__showOwnedCommand`).
(window as unknown as { __showOwnedCommand: (terminal: boolean) => void }).__showOwnedCommand = (terminal) => {
  const now = Date.now();
  const agents = [
    { id: "owner", parent: null, name: "Reviewer", task: "Review the tray", state: "running", startedAt: now - 90_000 },
  ];
  view.render(
    <section className="acpmux-shell" style={{ width: 720 }}>
      <div className="acpmux-main">
        <div className="acpmux-dock">
          <SubagentTray
            items={trayItems(
              agents,
              [
                {
                  id: "o/1",
                  command: "bun test test/running-strip.test.ts",
                  state: "running",
                  processId: "o/1",
                  toolCallId: "call-o",
                  subagent: "owner",
                  startedAt: now - 30_000,
                },
              ],
              [],
              true,
            )}
            working
            waiting={new Set()}
            onOpen={(id) => opened.push(`agent:${id}`)}
            onOpenCommand={(entry) => opened.push(`command:${entry.id}`)}
            canOpenTerminal={terminal}
            stop={async () => {}}
            stopProcess={async () => {}}
          />
        </div>
      </div>
    </section>,
  );
};
document.documentElement.dataset.harnessReady = "1";
