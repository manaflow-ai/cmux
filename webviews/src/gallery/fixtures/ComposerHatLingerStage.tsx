// l10n-allow-file: gallery fixtures (sample subagent tasks, commands, stage buttons), not shipped UI.
// The composer hat keeping what ended (subagents/trayLinger.ts) and moving its lines in and out
// (SubagentTray.tsx `TrayRow`), after Leo, 2026-11-07: "they, like, disappear instantly. So, like, if
// you have it expanded, then it just, like, it disappears, which is, like, bad". The real tray with the
// real linger, as App.tsx wires them, on a short grace so the expiry can be watched: a command
// starts and finishes (it stays as done), a subagent joins and leaves. The stage's buttons (outside
// the pane, for the play script and a person) drive it.
import { useMemo, useState, type CSSProperties } from "react";
import {
  finishedTrayItems,
  trayItemKey,
  trayItems,
  type TrayItem,
} from "../../agent-session/acpmux/subagents/runningTray";
import { SubagentTray } from "../../agent-session/acpmux/subagents/SubagentTray";
import type { Subagent } from "../../agent-session/acpmux/subagents/subagentFold";
import type { BackgroundCommand } from "../../agent-session/acpmux/session-info/processes";
import { lingeringTrayItems, trayItemEnd, useTrayLinger } from "../../agent-session/acpmux/subagents/trayLinger";

const NO_WAITING: ReadonlySet<string> = new Set();
const shown = { current: "gallery-linger" as string | undefined };
const TASKS = ["Review the fleet queue", "Check the docs agree", "Watch the nightly", "Read the build log"];

export type ComposerHatLingerState = "running" | "finished" | "three" | "lone";

export function ComposerHatLingerStage({
  start = "running",
  grace = 2_000,
  cooldown = 0,
  together = 0,
  looks = false,
}: {
  start?: ComposerHatLingerState;
  /// The linger's grace, short here so the expiry can be watched (the app's is TRAY_LINGER_MS).
  grace?: number;
  /// After a look ends, nothing goes for this long (the app's is TRAY_LOOK_COOLDOWN_MS); 0, none.
  cooldown?: number;
  /// Lines due within this long of the first leave with it (TRAY_LEAVE_TOGETHER_MS); 0, one by one.
  together?: number;
  /// The grace counts only while the hat could be seen (SubagentTray.tsx `onSeen`), as in the app.
  looks?: boolean;
}) {
  const [clock] = useState(() => Date.now());
  const [command, setCommand] = useState<BackgroundCommand["state"] | undefined>(
    start === "finished" ? "completed" : "running",
  );
  // When the command ended: stamped when it finishes or fails, so its time is what it ran.
  const [endedAt, setEndedAt] = useState(clock);
  const [agents, setAgents] = useState(start === "three" ? 3 : start === "lone" ? 0 : 1);
  const end = (state: BackgroundCommand["state"]) => {
    setEndedAt(Date.now());
    setCommand(state);
  };
  const [held, setHeld] = useState(false);
  const [seen, setSeen] = useState(true);
  const commands: BackgroundCommand[] = command
    ? [
        {
          id: "gallery-linger-command",
          command: "bun test test/subagent-tray.test.tsx",
          description: "Run the tray tests",
          state: command,
          toolCallId: "gallery-linger-command",
          startedAt: clock - 64_000,
          ...(command === "running" ? {} : { endedAt }),
        },
      ]
    : [];
  // When each subagent finished, by index (the stage's "Subagent finishes" ends the next one).
  const [agentEnds, setAgentEnds] = useState<readonly number[]>([]);
  const subagents: Subagent[] = Array.from({ length: agents }, (_, index) => ({
    id: `gallery-linger-agent-${index}`,
    parent: null,
    name: TASKS[index % TASKS.length]!,
    task: TASKS[index % TASKS.length]!,
    action: "Read docs/fleet.md",
    state: agentEnds[index] === undefined ? "running" : "done",
    startedAt: clock - 30_000 + index * 1_000,
    ...(agentEnds[index] === undefined ? {} : { endedAt: agentEnds[index] }),
  }));
  const items = useMemo(
    () => trayItems(subagents, commands, [], true),
    // eslint-disable-next-line react-hooks/exhaustive-deps -- the stage's own state is the key
    [agents, command, agentEnds],
  );
  const ended = useMemo((): TrayItem[] => {
    const done = commands.filter((entry) => entry.state !== "running");
    return [
      ...done.map((entry): TrayItem => ({ kind: "command", id: entry.id, command: entry })),
      ...finishedTrayItems(subagents, []),
    ];
    // eslint-disable-next-line react-hooks/exhaustive-deps -- the stage's own state is the key
  }, [agents, command, endedAt, agentEnds]);
  const live = useMemo(() => items.map(trayItemKey), [items]);
  const candidates = useMemo(
    () => ended.map((item) => ({ key: trayItemKey(item), endedAt: trayItemEnd(item) })),
    [ended],
  );
  const lingerOptions = useMemo(
    () => ({ grace, cooldown, together, seen: looks ? seen : true }),
    [grace, cooldown, together, looks, seen],
  );
  const kept = useTrayLinger("gallery-linger", live, candidates, held, lingerOptions);
  const finished = useMemo(() => lingeringTrayItems(ended, kept), [ended, kept]);
  const empty = items.length + finished.length === 0;
  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100vh", background: "var(--agent-page-bg)" }}>
      <div
        style={{
          display: "flex",
          flexWrap: "wrap",
          gap: "var(--ds-space-2)",
          padding: "var(--ds-space-2)",
          borderBottom: "1px solid var(--agent-border)",
        }}
      >
        <button type="button" data-stage="run" onClick={() => setCommand("running")}>
          Command runs
        </button>
        <button type="button" data-stage="finish" onClick={() => end("completed")}>
          Command finishes
        </button>
        <button type="button" data-stage="fail" onClick={() => end("failed")}>
          Command fails
        </button>
        <button type="button" data-stage="join" onClick={() => setAgents((current) => current + 1)}>
          Subagent joins
        </button>
        <button type="button" data-stage="leave" onClick={() => setAgents((current) => Math.max(0, current - 1))}>
          Subagent leaves
        </button>
        <button
          type="button"
          data-stage="agent-finish"
          onClick={() => setAgentEnds((current) => (current.length < agents ? [...current, Date.now()] : current))}
        >
          Subagent finishes
        </button>
        <span data-stage-held={held || undefined} data-stage-empty={empty || undefined}>
          {held ? "Held: nothing expires" : `Not held: what ended goes after ${grace / 1000}s`}
        </span>
      </div>
      <main className="acpmux-main" data-dock="float" style={{ position: "relative", flex: 1, minHeight: 0 }}>
        <div
          className="acpmux-dock"
          style={{ position: "absolute", insetInline: 0, bottom: 0, "--cv-inset": "16px" } as CSSProperties}
        >
          {!empty && (
            <SubagentTray
              key="gallery-linger"
              chat="gallery-linger"
              items={items}
              finished={finished}
              working
              waiting={NO_WAITING}
              onOpen={() => undefined}
              shown={shown}
              onHold={setHeld}
              onSeen={looks ? setSeen : undefined}
            />
          )}
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
