// l10n-allow-file: gallery fixtures (sample subagent tasks, stage buttons), not shipped UI.
// The composer hat's folded header with what runs, what ended and what was stopped, its Background
// tasks button and its chevron (SubagentTray.tsx, subagents.css), as App.tsx wires it over the
// composer. Leo, 2026-11-22, on "1 subagent · 1 subagent done · 1 stopped   17h 4m 46s" with its panel
// button sitting higher than the chevron: "the composer hat is also kinda wack with the button
// placement ... now some of the icons are misaligned. chief among them is the little sidebar button",
// then "idk tho that might just be the switch over from one completing subagent to another". The
// stage's buttons (outside the pane) hand the run over: the running subagent finishes, then the next
// one starts, so the header's counts change in place.
import { useMemo, useState, type CSSProperties } from "react";
import { finishedTrayItems, trayItems } from "../../agent-session/acpmux/subagents/runningTray";
import { SubagentTray } from "../../agent-session/acpmux/subagents/SubagentTray";
import type { Subagent } from "../../agent-session/acpmux/subagents/subagentFold";

const NO_WAITING: ReadonlySet<string> = new Set();
const shown = { current: "gallery-head-align" as string | undefined };
const HOUR = 3_600_000;

/// Where the hand-over starts: `mixed`, one runs, one is done, one was stopped (Leo's hat); `between`,
/// the running one just finished and the next has not started; `next`, the next one runs.
export type ComposerHatHeadAlignState = "mixed" | "between" | "next";

export function ComposerHatHeadAlignStage({ start = "mixed" }: { start?: ComposerHatHeadAlignState }) {
  const [clock] = useState(() => Date.now());
  // 0: the first runs; 1: it finished; 2: the next runs too.
  const [phase, setPhase] = useState(start === "mixed" ? 0 : start === "between" ? 1 : 2);
  const agents = useMemo((): Subagent[] => {
    const base = { parent: null, kind: "general-purpose", action: "Read docs/fleet.md" } as const;
    return [
      {
        ...base,
        id: "gallery-head-align-stopped",
        name: "Push relay",
        task: "Push relay for the lane bundles",
        state: "cancelled",
        stopReason: "user",
        startedAt: clock - 18 * HOUR,
        endedAt: clock - 17.5 * HOUR,
      },
      {
        ...base,
        id: "gallery-head-align-done",
        name: "Docs pass",
        task: "Tighten the running tray spec",
        state: "completed",
        startedAt: clock - 17.4 * HOUR,
        endedAt: clock - 17.2 * HOUR,
      },
      {
        ...base,
        id: "gallery-head-align-first",
        name: "Watch the nightly",
        task: "Watch the nightly",
        state: phase === 0 ? "running" : "completed",
        startedAt: clock - (17 * HOUR + 4 * 60_000 + 46_000),
        ...(phase === 0 ? {} : { endedAt: clock - 1_000 }),
      },
      ...(phase === 2
        ? [
            {
              ...base,
              id: "gallery-head-align-next",
              name: "Read the build log",
              task: "Read the build log",
              state: "running",
              startedAt: clock,
            } satisfies Subagent,
          ]
        : []),
    ];
  }, [clock, phase]);
  const items = useMemo(() => trayItems(agents, [], [], true), [agents]);
  const finished = useMemo(() => finishedTrayItems(agents, []), [agents]);
  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100vh", background: "var(--agent-page-bg)" }}>
      <div
        style={{
          display: "flex",
          // One line at every width, so a hand-over never moves the pane under it.
          flexWrap: "nowrap",
          overflow: "hidden",
          whiteSpace: "nowrap",
          gap: "var(--ds-space-2)",
          padding: "var(--ds-space-2)",
          borderBottom: "1px solid var(--agent-border)",
        }}
      >
        <button type="button" data-stage="finish" onClick={() => setPhase(1)}>
          Subagent finishes
        </button>
        <button type="button" data-stage="next" onClick={() => setPhase(2)}>
          Next subagent starts
        </button>
        <button type="button" data-stage="reset" onClick={() => setPhase(0)}>
          Reset
        </button>
        <span data-stage-phase={phase} hidden />
      </div>
      <main className="acpmux-main" data-dock="float" style={{ position: "relative", flex: 1, minHeight: 0 }}>
        <div
          className="acpmux-dock"
          style={{ position: "absolute", insetInline: 0, bottom: 0, "--cv-inset": "16px" } as CSSProperties}
        >
          <SubagentTray
            key="gallery-head-align"
            // Its marks and controls on one centre line: the `groups` header, which draws marks.
            foldHeadLook="groups"
            chat="gallery-head-align"
            items={items}
            finished={finished}
            working
            waiting={NO_WAITING}
            onOpen={() => undefined}
            onOpenPanel={() => undefined}
            onTuck={() => undefined}
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
