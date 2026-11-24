// l10n-allow-file: gallery fixtures (sample tool calls, stage labels), not shipped UI.
// The running turn's live line under a burst, replayed with no agent (Leo, 2026-11-24: "the sending
// messages in rapid succession is really bad looking. it's just your tool call/thinking glimmer text
// rapidly flickering up with very bad/nonexistent fade-in fade-out"). A scripted timeline loops: the
// line thinks, makes one call, then a burst of 30 changes in 2 s (a call, Thinking, a call, ...), a
// run of messages sent one after another, one long command, and rests. The real transcript row
// (rows/ThinkingRow.tsx) draws it, so its dwell (liveDwell.ts) and its roll (conversation.css) are
// the shipped ones; each look pins one of them, so a recording of each shows the difference.
import { useEffect, useLayoutEffect, useMemo, useState } from "react";
import { LiveDwellContext, LIVE_DWELL_MS } from "../../agent-session/acpmux/conversation/liveDwell";
import { LIVE_THINKING, THINKING } from "../../agent-session/acpmux/conversation/turns";
import type { AcpmuxRow } from "../../agent-session/acpmux/model";
import { ThinkingRow } from "../../agent-session/acpmux/rows/ThinkingRow";

/// What the live line draws from one moment on: a call (by id), else Thinking.
type Step = { at: number; call?: { id: string; title: string; shell?: boolean; sendTo?: string } };

const FILES = ["Thinking.tsx", "liveDwell.ts", "conversation.css", "ThinkingRow.tsx", "turns.ts"];
const GREPS = ["useRoll", "cv-roll-out", "LIVE_THINKING", "data-live-swap"];
const PEERS = ["tests", "review", "docs", "build"];

/// One loop of BURST_LOOP_MS.
function timeline(): Step[] {
  const steps: Step[] = [{ at: 0 }];
  let at = 1_200;
  steps.push({ at, call: { id: "c-read", title: `Read ${FILES[0]}` } });
  at += 1_400;
  steps.push({ at });
  at += 900;
  // The burst: 30 changes in 2 s, a call and Thinking in turn, about 67 ms apart.
  for (let i = 0; i < 30; i++, at += 67)
    steps.push(
      i % 2 === 0
        ? {
            at,
            call:
              i % 6 === 4
                ? { id: `c-burst-${i}`, title: `grep -n ${GREPS[i % GREPS.length]} src`, shell: true }
                : { id: `c-burst-${i}`, title: `Read ${FILES[i % FILES.length]}` },
          }
        : { at },
    );
  at += 1_200;
  // Messages sent in rapid succession, a Thinking between each.
  for (let i = 0; i < 8; i++, at += 120)
    steps.push(
      i % 2 === 0 ? { at, call: { id: `c-send-${i}`, title: "", sendTo: PEERS[(i / 2) % PEERS.length] } } : { at },
    );
  at += 1_000;
  steps.push({ at, call: { id: "c-test", title: "bun test test/live-line-burst.test.tsx", shell: true } });
  at += 2_400;
  steps.push({ at });
  return steps;
}

export const BURST_LOOP_MS = 12_000;
const STEPS = timeline();

/// How the live line changes its words in this variant.
export type LiveLineBurstLook = "before" | "dwell-roll" | "feather" | "cross" | "reduced";

/// The dwell and the hand-over look (conversation.css `data-live-swap`) each look pins.
const LOOKS: Record<LiveLineBurstLook, { dwell: number; swap?: string; motion?: string }> = {
  before: { dwell: 0, swap: "hard" },
  "dwell-roll": { dwell: LIVE_DWELL_MS, swap: "hard" },
  feather: { dwell: LIVE_DWELL_MS },
  cross: { dwell: LIVE_DWELL_MS, swap: "cross" },
  reduced: { dwell: LIVE_DWELL_MS, motion: "reduced" },
};

export function LiveLineBurstStage({ look = "feather" }: { look?: LiveLineBurstLook }) {
  const pinned = LOOKS[look];
  const [clock] = useState(() => Date.now());
  const [now, setNow] = useState(clock);
  useEffect(() => {
    let frame = requestAnimationFrame(function tick() {
      setNow(Date.now());
      frame = requestAnimationFrame(tick);
    });
    return () => cancelAnimationFrame(frame);
  }, []);
  useLayoutEffect(() => {
    if (!pinned.motion) return;
    const root = document.documentElement;
    const before = root.dataset.cmuxMotion;
    root.dataset.cmuxMotion = pinned.motion;
    return () => {
      if (before === undefined) delete root.dataset.cmuxMotion;
      else root.dataset.cmuxMotion = before;
    };
  }, [pinned.motion]);
  const t = (now - clock) % BURST_LOOP_MS;
  const index = STEPS.findLastIndex((step) => step.at <= t);
  const step = STEPS[Math.max(0, index)]!;
  const loop = Math.floor((now - clock) / BURST_LOOP_MS);
  const call = step.call;
  // Kept by identity while the step holds, as the transcript's rows are.
  const row = useMemo(
    () =>
      ({
        id: LIVE_THINKING,
        kind: THINKING,
        version: index + loop * STEPS.length + 1,
        at: clock - 34_000,
        ...(call
          ? {
              doing: call.sendTo ? "" : call.title,
              doingCall: `${loop}:${index}:${call.id}`,
              doingAt: clock + loop * BURST_LOOP_MS + step.at,
              ...(call.shell ? { doingShell: true, doingCommand: true } : {}),
              ...(call.sendTo ? { doingSendTo: call.sendTo } : {}),
            }
          : { phaseAt: clock + loop * BURST_LOOP_MS + step.at }),
        turnTotal: true,
      }) as AcpmuxRow,
    [index, loop, clock, call, step.at],
  );
  return (
    <LiveDwellContext.Provider value={pinned.dwell}>
      <div
        className="acpmux-shell"
        data-live-swap={pinned.swap}
        style={{ height: "100vh", background: "var(--agent-page-bg)" }}
      >
        <div className="acpmux-thread" style={{ position: "relative", padding: "24px 16px 0", maxWidth: 560 }}>
          <article className="acpmux-row acpmux-thinking" data-row-id={LIVE_THINKING} style={{ position: "relative" }}>
            <ThinkingRow row={row} onToggleActivity={() => {}} expanded={false} />
          </article>
          <output
            data-stage="clock"
            style={{ position: "absolute", right: 16, top: 4, opacity: 0.4, fontSize: "var(--text-caption)" }}
          >
            {(t / 1000).toFixed(1)}s
          </output>
          <output
            data-stage="step"
            style={{ display: "block", marginTop: 24, opacity: 0.4, fontSize: "var(--text-caption)" }}
          >
            {call ? (call.sendTo ? `send to ${call.sendTo}` : call.title) : "Thinking"}
          </output>
        </div>
      </div>
    </LiveDwellContext.Provider>
  );
}
