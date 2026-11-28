// l10n-allow-file: gallery fixtures (sample subagent tasks, tool steps, stage buttons), not shipped UI.
// The two status lines that hand over from one step to the next, side by side: the composer hat's
// header with one subagent (subagents/SubagentTray.tsx, its step in `Tick` slide) and the running
// turn's live line (conversation/Thinking.tsx `useRoll`), Thinking to a tool call to Thinking again.
// One stage button steps both (Leo, 2026-11-11: "the composer hat the way it switches between text is
// ugly bc it's too slow on the transitions and there's breif moments where it just looks like a blank
// tear that then switches"), so a play, a frame test (test/status-swap-frames.test.ts) and a person
// watch the same swap.
import { useEffect, useState, type CSSProperties } from "react";
import { trayItems, finishedTrayItems } from "../../agent-session/acpmux/subagents/runningTray";
import { SubagentTray } from "../../agent-session/acpmux/subagents/SubagentTray";
import type { Subagent } from "../../agent-session/acpmux/subagents/subagentFold";
import { Thinking } from "../../agent-session/acpmux/conversation/Thinking";
import { WorkingCountsContext, type WorkingCounts } from "../../agent-session/acpmux/conversation/workingForModel";
import { Button } from "../../ui/Button";

/// The hat's subagent steps, and the live line's: Thinking (no call), a call, Thinking, a command.
const HAT_STEPS = ["Read SubagentTray.tsx", "Grep latestLine", "Edit trayMotion.tsx", "Read conversation.css"];
const LINE_STEPS: ({ doing?: string; shell?: boolean } | undefined)[] = [
  undefined,
  { doing: "Read VirtualTranscript.tsx" },
  undefined,
  { doing: "git status --short", shell: true },
];
/// Leo's recording (2026-11-11, his NIGHTLY, the end of a turn): "Thinking 1m · 1.7K tokens", then
/// "Sending a message 1m · 1.7K tokens" while the agent's SendMessage runs, then "Thinking 1m 5s ·
/// 2.5K tokens", the turn's clock and tokens going on under the words.
const LEO_STEPS: { doing?: string; tokens: number }[] = [
  { tokens: 1_700 },
  { doing: "Sending a message", tokens: 1_700 },
  { tokens: 2_500 },
];
/// A turn that sends messages in quick succession (Leo, 2026-11-25: "the sending messages in rapid
/// succession is really bad looking"): the line flips between Thinking, a send and a call every
/// BURST_GAP_MS, quicker than the line's dwell (Thinking.tsx `LINE_DWELL_MS`).
const BURST_STEPS: { doing?: string; sendTo?: string }[] = [
  { doing: "SendMessage", sendTo: "tests" },
  {},
  { doing: "SendMessage", sendTo: "reviewer" },
  { doing: "Read ThinkingRow.tsx" },
  {},
  { doing: "SendMessage", sendTo: "tests" },
  {},
  { doing: "SendMessage", sendTo: "docs" },
  {},
];
export const BURST_GAP_MS = 60;
const counts = (tokens: number): WorkingCounts => ({
  tokens,
});
const NO_WAITING: ReadonlySet<string> = new Set();
const shown = { current: "gallery-status-swap" as string | undefined };

export function StatusSwapStage({ sequence, dwell = true }: { sequence?: "leo" | "burst"; dwell?: boolean }) {
  const [clock] = useState(() => Date.now());
  const [step, setStep] = useState(0);
  const [burst, setBurst] = useState(-1);
  useEffect(() => {
    if (dwell) delete document.documentElement.dataset.liveDwell;
    else document.documentElement.dataset.liveDwell = "off";
    return () => {
      delete document.documentElement.dataset.liveDwell;
    };
  }, [dwell]);
  // One burst: each step BURST_GAP_MS after the last, then the line rests on Thinking.
  useEffect(() => {
    if (burst < 0 || burst >= BURST_STEPS.length - 1) return;
    const id = window.setTimeout(() => setBurst((current) => current + 1), BURST_GAP_MS);
    return () => window.clearTimeout(id);
  }, [burst]);
  const sent = sequence === "burst" && burst >= 0 ? BURST_STEPS[burst] : undefined;
  const lead: Subagent = {
    id: "gallery-status-swap-lead",
    parent: null,
    name: "Diagnose nightly lag, idle fleet",
    task: "Diagnose nightly lag, idle fleet",
    kind: "general-purpose",
    action: HAT_STEPS[step % HAT_STEPS.length],
    state: "running",
    startedAt: clock - 192_000,
  };
  const items = trayItems([lead], [], [], true);
  const finished = finishedTrayItems([lead], []);
  const line = LINE_STEPS[step % LINE_STEPS.length];
  const leo = sequence === "leo" ? LEO_STEPS[step % LEO_STEPS.length] : undefined;
  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100vh", background: "var(--agent-page-bg)" }}>
      <div
        style={{ display: "flex", gap: "var(--ds-space-2)", padding: 8, borderBottom: "1px solid var(--agent-border)" }}
      >
        <Button bare type="button" data-stage="next" onClick={() => setStep((current) => current + 1)}>
          Next step
        </Button>
        {sequence === "burst" ? (
          <Button bare type="button" data-stage="burst" onClick={() => setBurst(0)}>
            Send a burst
          </Button>
        ) : null}
      </div>
      <main className="acpmux-main" data-dock="float" style={{ position: "relative", flex: 1, minHeight: 0 }}>
        <div className="acpmux-thread" style={{ position: "relative", padding: "16px 16px 0" }}>
          <article className="acpmux-row acpmux-thinking" data-status-swap="line" style={{ position: "relative" }}>
            {leo ? (
              <WorkingCountsContext.Provider value={counts(leo.tokens)}>
                <Thinking since={clock - 60_000} doing={leo.doing} below />
              </WorkingCountsContext.Provider>
            ) : sequence === "burst" ? (
              <Thinking since={clock - 34_000} doing={sent?.doing} sendTo={sent?.sendTo} below />
            ) : (
              <Thinking since={clock - 34_000} doing={line?.doing} doingShell={line?.shell} below />
            )}
          </article>
        </div>
        <div
          className="acpmux-dock"
          style={{ position: "absolute", insetInline: 0, bottom: 0, "--cv-inset": "16px" } as CSSProperties}
        >
          <SubagentTray
            key="gallery-status-swap"
            chat="gallery-status-swap"
            items={items}
            finished={finished}
            working
            waiting={NO_WAITING}
            onOpen={() => undefined}
            shown={shown}
            // The exact step, sliding in as it comes: this stage is about that hand-over (hatStep.experiment.ts).
            stepLook="exact"
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
