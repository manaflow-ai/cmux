// l10n-allow-file: gallery fixtures (sample subagent tasks, tool calls, stage buttons), not shipped UI.
// The composer hat under a burst of calls, replayed with no agent (Leo, 2026-11-22: "the swapping
// gets jarring. it's too adhd-ish. you need to think hard about the various cases, various types of
// numbers, all that"). A scripted timeline loops: a subagent thinks, makes one call, a burst of 5, a
// burst of 50 at 60 ms apart, runs one long command, and fails one; in `parallel` three subagents do
// it at once, offset. Each hatStep.experiment.ts arm draws the same timeline (view Compare arms), so a
// recording of each shows how much of the hat moves.
import { useEffect, useMemo, useState, type CSSProperties } from "react";
import { trayItems, finishedTrayItems } from "../../agent-session/acpmux/subagents/runningTray";
import { SubagentTray } from "../../agent-session/acpmux/subagents/SubagentTray";
import type { Subagent } from "../../agent-session/acpmux/subagents/subagentFold";
import { Thinking } from "../../agent-session/acpmux/conversation/Thinking";
import type { HatStepArm } from "../../agent-session/acpmux/subagents/hatStep.experiment";

export type HatBurstScene = "lone" | "parallel";

type Call = { at: number; action?: string; kind?: string };

const FILES = ["SubagentTray.tsx", "trayMotion.tsx", "AgentLine.tsx", "subagents.css", "trayDetail.ts", "hatStep.ts"];
const GREPS = ["latestLine", "actionKind", "Tick slide", "useRoll", "steadyCounts"];
const COMMANDS = ["git status --short", "bun test test/composer-hat-lone.test.tsx", "cargo test -p acpmux workflow"];

/// One subagent's calls over one loop of LOOP_MS: when each starts and what it is.
function timeline(offset: number): Call[] {
  const calls: Call[] = [{ at: 0 }];
  let at = 1_600;
  calls.push({ at, action: `Read ${FILES[0]}`, kind: "read" });
  at += 2_400;
  for (let i = 0; i < 5; i++, at += 350)
    calls.push({ at, action: i % 2 ? `Grep ${GREPS[i]}` : `Read ${FILES[i + 1]}`, kind: "read" });
  at += 1_400;
  calls.push({ at, action: `Edit ${FILES[1]}`, kind: "edit" });
  at += 1_800;
  for (let i = 0; i < 50; i++, at += 60) {
    const kind = i % 7 === 6 ? "edit" : i % 3 === 2 ? "search" : "read";
    const action =
      kind === "edit"
        ? `Edit ${FILES[i % FILES.length]}`
        : kind === "search"
          ? `Grep ${GREPS[i % GREPS.length]}`
          : `Read ${FILES[i % FILES.length]}`;
    calls.push({ at, action, kind });
  }
  at += 1_200;
  calls.push({ at, action: COMMANDS[1], kind: "execute" });
  at += 5_000;
  calls.push({ at, action: COMMANDS[0], kind: "execute" });
  at += 900;
  calls.push({ at, action: "WebFetch https://docs.rs/tokio", kind: "fetch" });
  at += 1_600;
  calls.push({ at, action: COMMANDS[2], kind: "execute" });
  return calls.map((call) => ({ ...call, at: call.at + offset }));
}

export const LOOP_MS = 24_000;
const TASKS = ["Calm the composer hat", "Review PR #49824", "Port the burst fixture"];
const NO_WAITING: ReadonlySet<string> = new Set();
const shown = { current: "gallery-hat-burst" as string | undefined };

export function HatBurstStage({ scene = "lone", arm }: { scene?: HatBurstScene; arm?: HatStepArm }) {
  const [clock] = useState(() => Date.now());
  const [now, setNow] = useState(clock);
  const count = scene === "parallel" ? 3 : 1;
  const lines = useMemo(() => Array.from({ length: count }, (_, i) => timeline(i * 700)), [count]);
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 40);
    return () => clearInterval(timer);
  }, []);
  const t = (now - clock) % LOOP_MS;
  const agents: Subagent[] = lines.map((calls, i) => {
    const last = [...calls].reverse().find((call) => call.at <= t) ?? calls[0]!;
    return {
      id: `gallery-hat-burst-${i}`,
      parent: null,
      name: TASKS[i]!,
      task: TASKS[i]!,
      kind: "general-purpose",
      state: "running",
      startedAt: clock - 95_000 - i * 20_000,
      ...(last.action ? { action: last.action } : {}),
      ...(last.kind ? { actionKind: last.kind } : {}),
      ...(last.kind === "execute" ? { actionShell: true } : {}),
      toolUses: calls.filter((call) => call.action && call.at <= t).length,
    };
  });
  const items = trayItems(agents, [], [], true);
  const finished = finishedTrayItems(agents, []);
  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100vh", background: "var(--agent-page-bg)" }}>
      <main className="acpmux-main" data-dock="float" style={{ position: "relative", flex: 1, minHeight: 0 }}>
        <div className="acpmux-thread" style={{ position: "relative", padding: "16px 16px 0" }}>
          <article className="acpmux-row acpmux-thinking" style={{ position: "relative" }}>
            <Thinking since={clock - 34_000} below />
          </article>
          <output
            data-stage="clock"
            style={{ position: "absolute", right: 16, top: 16, opacity: 0.4, fontSize: "var(--text-caption)" }}
          >
            {(t / 1000).toFixed(1)}s
          </output>
        </div>
        <div
          className="acpmux-dock"
          style={{ position: "absolute", insetInline: 0, bottom: 0, "--cv-inset": "16px" } as CSSProperties}
        >
          <SubagentTray
            key="gallery-hat-burst"
            chat="gallery-hat-burst"
            items={items}
            finished={finished}
            working
            waiting={NO_WAITING}
            onOpen={() => undefined}
            shown={shown}
            stepLook={arm}
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
