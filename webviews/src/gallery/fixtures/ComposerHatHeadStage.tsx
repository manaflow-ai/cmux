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
import { HatRail } from "../../agent-session/acpmux/subagents/HatRail";
import { hatSideLook } from "../../agent-session/acpmux/subagents/hatSide.experiment";
import { rememberTrayOpen } from "../../agent-session/acpmux/subagents/trayFoldMemory";
import { experimentArm } from "../../experiments/experiment";
import { Icon } from "../../agent-session/acpmux/icons/Icon";

const STEPS = ["Bash", "Read SubagentTray.tsx", "Grep latestLine", "Edit trayMotion.tsx", "Bash"];
const NO_WAITING: ReadonlySet<string> = new Set();
const shown = { current: "gallery-hat" as string | undefined };

export type ComposerHatHeadState = "running" | "done" | "two" | "joined-command" | "two-and-command";

export function ComposerHatHeadStage({
  start = "running",
  tuck = false,
  standIn = false,
}: {
  start?: ComposerHatHeadState;
  /// The hat can tuck away: its tuck control shows at its top middle (hatTuck.experiment.ts).
  tuck?: boolean;
  /// A stand-in composer with its prompt and bottom line (+, mic, Send), so the side arms'
  /// placements (hatSide.experiment.ts) read at a real composer's size. Unset, the plain box.
  standIn?: boolean;
}) {
  const [clock] = useState(() => Date.now());
  const [step, setStep] = useState(0);
  const [done, setDone] = useState(start === "done");
  const [joined, setJoined] = useState(start === "two" || start === "two-and-command" ? 1 : 0);
  const [command, setCommand] = useState(start === "joined-command" || start === "two-and-command");
  // Where the marks sit (hatSide.experiment.ts): the hat on top (today), or a rail beside the composer
  // or on its bottom line, whose list control shows the hat, opened, over the composer.
  const [arm] = useState(() => experimentArm(hatSideLook));
  const side = standIn ? arm : "top";
  const [listOpen, setListOpen] = useState(false);
  const [opened, setOpened] = useState<string[]>([]);
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
          {(side === "top" || listOpen) && (
            <SubagentTray
              key={`gallery-hat-${side}-${listOpen}`}
              chat="gallery-hat"
              items={items}
              finished={finished}
              working={!done || joined > 0 || command}
              waiting={NO_WAITING}
              onOpen={(id) => setOpened((current) => [...current, id])}
              shown={shown}
              onTuck={tuck ? () => undefined : undefined}
              // Beside the composer, the hat's fold puts it away, as in the pane (App.tsx, hatSidePlace.ts).
              onFold={side !== "top" ? () => setListOpen(false) : undefined}
            />
          )}
          {!standIn ? (
            <div className="acpmux-composer">
              <div
                className="acpmux-composer-box"
                style={{
                  margin: "0 16px 16px",
                  height: 72,
                  borderRadius: 12,
                  background: "var(--acpmux-composer-tray)",
                }}
              />
            </div>
          ) : (
            <div className="acpmux-composer">
              <div
                data-stage-composer-row
                style={{
                  display: "flex",
                  alignItems: "flex-end",
                  gap: "var(--ds-space-1)",
                  margin: "0 16px 16px",
                  flexDirection: side === "left-rail" ? "row-reverse" : "row",
                }}
              >
                <div
                  className="acpmux-composer-box"
                  style={{
                    flex: 1,
                    minWidth: 0,
                    display: "flex",
                    flexDirection: "column",
                    justifyContent: "space-between",
                    gap: "var(--ds-space-2)",
                    minHeight: 72,
                    padding: "var(--ds-space-2) var(--ds-space-2) var(--ds-space-1)",
                    borderRadius: 12,
                    background: "var(--acpmux-composer-tray)",
                    color: "var(--agent-muted)",
                    fontSize: "var(--text-control)",
                  }}
                >
                  <span style={{ paddingInline: "var(--ds-space-1)" }}>Ask anything</span>
                  {/* The bottom line: + at its start, mic and Send at its end, always on this line. */}
                  <div
                    data-stage-bottom-line
                    style={{ display: "flex", alignItems: "center", gap: "var(--ds-space-1)" }}
                  >
                    <span style={STAND_IN_BUTTON} aria-hidden="true">
                      <Icon name="composer.add" size={14} />
                    </span>
                    {side === "bottom-line" && (
                      <HatRail
                        side="bottom-line"
                        items={items}
                        finished={finished}
                        waiting={NO_WAITING}
                        listOpen={listOpen}
                        onOpen={(id) => setOpened((current) => [...current, id])}
                        onList={(open) => openList(open, setListOpen)}
                      />
                    )}
                    <span style={{ flex: 1 }} />
                    <span style={STAND_IN_BUTTON} aria-hidden="true" data-stage-mic>
                      <span
                        style={{
                          width: 6,
                          height: 10,
                          borderRadius: "var(--ds-radius-sm)",
                          border: "1.5px solid currentColor",
                        }}
                      />
                    </span>
                    <span
                      style={{ ...STAND_IN_BUTTON, background: "var(--agent-accent)", color: "white" }}
                      aria-hidden="true"
                    >
                      <Icon name="composer.send" size={14} />
                    </span>
                  </div>
                </div>
                {(side === "right-rail" || side === "left-rail") && (
                  <HatRail
                    side={side}
                    items={items}
                    finished={finished}
                    waiting={NO_WAITING}
                    listOpen={listOpen}
                    onOpen={(id) => setOpened((current) => [...current, id])}
                    onList={(open) => openList(open, setListOpen)}
                  />
                )}
              </div>
            </div>
          )}
          {opened.length > 0 && (
            <output data-stage-opened style={{ position: "absolute", top: 8, left: 16, color: "var(--agent-muted)" }}>
              Opened {opened[opened.length - 1]}
            </output>
          )}
        </div>
      </main>
    </div>
  );
}

const STAND_IN_BUTTON: CSSProperties = {
  display: "inline-flex",
  alignItems: "center",
  justifyContent: "center",
  width: 24,
  height: 24,
  borderRadius: 12,
  color: "var(--agent-muted)",
};

/// The rail's list control shows the hat over the composer, opened on its lines.
function openList(open: boolean, setListOpen: (open: boolean) => void) {
  if (open) rememberTrayOpen("gallery-hat", true);
  setListOpen(open);
}
