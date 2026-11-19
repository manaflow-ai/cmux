// l10n-allow-file: test fixture rows, not shipped UI.
// The whole Session Info panel of a god chat, as Leo's claude-sr2-coord-old has it (2026-11-19: 28,408
// background shells, 26 sources, 38 subagents; "dam this is slow as shit on the sesion info"). The page
// draws SessionInfo with the registry as one of two shapes:
//   ?mode=whole  every process (what the page held once Session Info opened, before this change);
//   ?mode=window the running ones and the newest ended (processes.ts PROCESS_LIST_RECENT), the rest
//                counted in `olderProcesses` (after).
// `window.__press(selector)` presses a section's head or fold and answers the ms from the press to the
// painted frame; `window.__parse()` answers the ms to parse the registry's reply JSON for the mode, the
// work the page does on open (test/session-info-god-chat-cost.test.ts).
import { createRoot } from "react-dom/client";
import { chat } from "../../src/gallery/fixtures/acpmux";
import { sessionSummary } from "../../src/agent-session/acpmux/summary/sessionSummary";
import { SessionInfo, SessionInfoPanel } from "../../src/agent-session/acpmux/session-info/SessionInfo";
import { PROCESS_LIST_RECENT, type SessionInfoProcess } from "../../src/agent-session/acpmux/session-info/processes";
import type { Subagent } from "../../src/agent-session/acpmux/subagents/subagentFold";
import "../../src/pages/shared/desktop.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/session-info/sessionInfo.css";

const params = new URLSearchParams(location.search);
const mode = params.get("mode") === "window" ? "window" : "whole";
const n = Number(params.get("n") ?? "28408");
const at = Date.now();

/// Process `index` of `n`: the last one runs (an old `timeout` loop, as Leo's did), the rest ended,
/// newest last, in the order they started.
const processAt = (index: number): SessionInfoProcess => {
  const running = index === 0;
  return {
    id: `god/task-${index}`,
    toolCallId: `call-${index}`,
    command: running ? "cd ~/Projects && timeout 900 glaeda-gh wait pr 1" : `glaeda-gh wait pid ${index} --timeout 110`,
    startedAt: at - (n - index) * 2_000 - 60_000,
    state: running ? "running" : "exited",
    ...(running ? {} : { endedAt: at - (n - index) * 2_000 }),
  };
};
const all = Array.from({ length: n }, (_, index) => processAt(index));
const ended = all.filter((process) => process.state !== "running");
const kept =
  mode === "whole"
    ? all
    : [...all.filter((process) => process.state === "running"), ...ended.slice(-PROCESS_LIST_RECENT)];
const older = mode === "whole" ? 0 : n - kept.length;

const agents: Subagent[] = Array.from({ length: 38 }, (_, index) => ({
  id: `agent-${index}`,
  parent: null,
  name: `Helper ${index + 1}`,
  task: "Check one part of the change",
  state: index < 5 ? "failed" : "completed",
  startedAt: at - (index + 1) * 120_000,
  endedAt: at - index * 100_000,
}));
const local = chat([]);
const sources = Array.from({ length: 26 }, (_, index) => ({
  url: `https://example.com/doc/${index}`,
  label: `example.com/doc/${index}`,
  kind: "url" as const,
}));

function Panel() {
  return (
    <div className="acpmux-shell" style={{ display: "flex", justifyContent: "flex-end", height: "100%" }}>
      <SessionInfoPanel width={320} placement="overlay" chrome="close">
        <SessionInfo
          summary={local.summary!}
          made={{ ...sessionSummary([]), sources }}
          agents={agents}
          processes={kept}
          listed
          olderProcesses={older}
          onLoadOlderProcesses={() => undefined}
          onStopProcess={async () => undefined}
          onOpenUrl={() => undefined}
        />
      </SessionInfoPanel>
    </div>
  );
}

createRoot(document.getElementById("root")!).render(<Panel />);

declare global {
  interface Window {
    __press(selector: string): Promise<number>;
    __parse(): number;
    __mode: { mode: string; held: number; older: number };
  }
}

const painted = () =>
  new Promise<void>((resolve) =>
    requestAnimationFrame(() => {
      const channel = new MessageChannel();
      channel.port1.onmessage = () => resolve();
      channel.port2.postMessage(0);
    }),
  );

window.__mode = { mode, held: kept.length, older };
window.__press = async (selector: string) => {
  const button = document.querySelector<HTMLElement>(selector);
  if (!button) throw new Error(`no ${selector}`);
  const start = performance.now();
  button.click();
  await painted();
  return performance.now() - start;
};
// The reply the page parses on open: every page of the whole list, or the one window reply.
const reply = JSON.stringify({
  processes: kept.map((process) => ({ ...process, sessionId: "god", detail: "x".repeat(700) })),
});
window.__parse = () => {
  const start = performance.now();
  JSON.parse(reply);
  return performance.now() - start;
};
