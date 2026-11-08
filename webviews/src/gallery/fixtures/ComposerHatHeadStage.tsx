// l10n-allow-file: gallery fixtures (sample subagent tasks, tool steps, stage buttons), not shipped UI.
// The composer hat's header over a stand-in composer (subagents/SubagentTray.tsx): the real tray with
// one subagent whose step changes (its line hands over from one step to the next), a second joining,
// and the first finishing. The stage's buttons (outside the pane, for the play script and a person)
// drive it, so the slide, the count's roll, the done mark and both chevron places can be watched.
import { useState, type CSSProperties } from "react";
import { trayItems, finishedTrayItems } from "../../agent-session/acpmux/subagents/runningTray";
import { SubagentTray } from "../../agent-session/acpmux/subagents/SubagentTray";
import type { Subagent } from "../../agent-session/acpmux/subagents/subagentFold";
import type { BackgroundCommand } from "../../agent-session/acpmux/session-info/processes";

const STEPS = ["Bash", "Read SubagentTray.tsx", "Grep latestLine", "Edit trayMotion.tsx", "Bash"];
const NO_WAITING: ReadonlySet<string> = new Set();
const shown = { current: "gallery-hat" as string | undefined };

export type ComposerHatHeadState = "running" | "done" | "two" | "joined-command";

export function ComposerHatHeadStage({ start = "running" }: { start?: ComposerHatHeadState }) {
  const [clock] = useState(() => Date.now());
  const [step, setStep] = useState(0);
  const [done, setDone] = useState(start === "done");
  const [joined, setJoined] = useState(start === "two" ? 1 : 0);
  const [command, setCommand] = useState(start === "joined-command");
  const lead: Subagent = {
    id: "gallery-hat-lead",
    parent: null,
    name: "Diagnose nightly lag, idle fleet",
    task: "Diagnose nightly lag, idle fleet",
    kind: "general-purpose",
    action: STEPS[step % STEPS.length],
    state: done ? "completed" : "running",
    startedAt: clock - 492_000,
    ...(done ? { endedAt: clock } : {}),
  };
  const others: Subagent[] = Array.from({ length: joined }, (_, index) => ({
    id: `gallery-hat-joined-${index}`,
    parent: null,
    name: index % 2 ? "Check the docs agree" : "Review the fleet queue",
    task: index % 2 ? "Check the docs agree" : "Review the fleet queue",
    action: "Read docs/fleet.md",
    state: "running",
    startedAt: clock - 20_000 + index * 1_000,
  }));
  const commands: BackgroundCommand[] = command
    ? [
        {
          id: "gallery-hat-command",
          command: "cmux-ci wait --sha 5633dcdb0084b6",
          description: "Wait for the fleet build",
          state: "running",
          startedAt: clock - 4_000,
        },
      ]
    : [];
  const agents = [lead, ...others];
  const items = trayItems(
    agents.filter((agent) => agent.state === "running"),
    commands,
    [],
    true,
  );
  const finished = finishedTrayItems(agents, []);
  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100vh", background: "var(--agent-page-bg)" }}>
      <div
        style={{ display: "flex", gap: "var(--ds-space-2)", padding: 8, borderBottom: "1px solid var(--agent-border)" }}
      >
        <button type="button" data-stage="step" onClick={() => setStep((current) => current + 1)}>
          Next step
        </button>
        <button type="button" data-stage="join" onClick={() => setJoined((current) => current + 1)}>
          Subagent joins
        </button>
        <button type="button" data-stage="command" onClick={() => setCommand(true)}>
          Command joins
        </button>
        <button type="button" data-stage="finish" onClick={() => setDone(true)}>
          Finish
        </button>
      </div>
      <main className="acpmux-main" data-dock="float" style={{ position: "relative", flex: 1, minHeight: 0 }}>
        <div
          className="acpmux-dock"
          style={{ position: "absolute", insetInline: 0, bottom: 0, "--cv-inset": "16px" } as CSSProperties}
        >
          <SubagentTray
            key="gallery-hat"
            chat="gallery-hat"
            items={items}
            finished={finished}
            working={!done || joined > 0 || command}
            waiting={NO_WAITING}
            onOpen={() => undefined}
            shown={shown}
          />
          <div className="acpmux-composer">
            <div
              className="acpmux-composer-box"
              style={{ margin: "0 16px 16px", height: 72, borderRadius: 12, background: "var(--acpmux-composer-tray)" }}
            />
          </div>
        </div>
      </main>
    </div>
  );
}
