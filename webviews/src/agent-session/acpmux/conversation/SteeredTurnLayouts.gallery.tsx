// l10n-allow-file: gallery fixtures (sample prompts, commands and replies), not shipped UI.
// How a turn the person steered lays out, live and finished, for Leo's pick (hq#18554 section 4; Leo,
// 2026-11-22: "these cases are maybe taste calls, but potentially we can just stick the steered
// together. not sure tho." and "clearly there's still improper folds and stuff"). One turn with one
// steer and one with two, each live (a call in flight after the last steer), finished and closed,
// finished and opened, and `run-*`: live until End the turn lands the answer and the turn folds (the clip).
// Compare the arms of turnFoldSteered.experiment.ts (the gallery's arm picker, or `exp`/`arm` query):
//   V1 `in-order` (shipped): a Worked for per stretch, each steer between them where it arrived;
//   V2 `stacked`: the steers stacked under the prompt, live and finished, one Worked for for the turn;
//   V3 `inline`: one Worked for for the turn, each steer inside it where it arrived;
//   V4 `nested-open`: one Worked for at the top, each steer and the reply before it in sight below it.
import { useEffect, useMemo, useRef, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { VirtualTranscript } from "../App";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { turnView } from "./turns";
import { turnFoldSteered } from "./turnFoldSteered.experiment";

type Phase = "live" | "ended" | "open" | "run";
type Props = { steers: 1 | 2; phase: Phase };

const NOW = Date.UTC(2026, 10, 22, 12, 30, 0);
const at = (seconds: number) => NOW - 120_000 + seconds * 1000;

let ids = 0;
const command = (description: string, text: string, status = "completed"): AcpmuxActivity => {
  ids += 1;
  return {
    kind: "tool",
    text,
    tool: {
      id: `steer-c${ids}`,
      title: text,
      kind: "execute",
      status,
      description,
      command: text,
      exitCode: status === "completed" ? 0 : undefined,
      output: status === "completed" ? "ok\n" : undefined,
    },
  };
};
const thought = (text: string): AcpmuxActivity => ({ kind: "thought", text });
const run = (id: string, seconds: number, items: AcpmuxActivity[]): AcpmuxRow => ({
  id,
  kind: "activity",
  version: items.length,
  at: at(seconds),
  items,
  toolCount: items.filter((item) => item.tool).length,
});

const PROMPT =
  "you guys also need to be testing flicks of extremely fast input for scrolling and resizing/mouse " +
  "movement and typing/pasting/switching workspaces around. we need to test like power users more often.";
const STEER_1 = 'the "make cmux yours" ui, we need to hill climb it';
const STEER_2 = "and check the nightly before you start either";

/// The turn's rows: work, a reply, the first steer, work, (the second steer, work), then the answer.
/// `live`: stops with a call in flight after the last steer.
function turnRows(steers: 1 | 2, ended: boolean): AcpmuxRow[] {
  ids = 0;
  const rows: AcpmuxRow[] = [
    { id: "steer-prompt", kind: "user", version: 1, at: at(0), text: PROMPT },
    run("steer-run-1", 2, [
      thought("Which helper takes this: the perf sensor or the layout-shift fuzzer? The fuzzer already drives input."),
      command("Listed the open lanes", "acpmux ls --json"),
      command("Read the fuzzer's axes", "rg -n 'axes' webviews/scripts/fold-fuzz.ts"),
    ]),
    {
      id: "steer-reply-1",
      kind: "assistant",
      version: 1,
      at: at(20),
      text: "The layout-shift fuzzer already drives scrolling and resizing, so I'm adding fast-input flicks to its axes.",
    },
    { id: "steer-1", kind: "user", version: 1, at: at(23), text: STEER_1, steer: "landed" },
    run("steer-run-2", 25, [
      command("Found the Make cmux yours page", "rg -ln 'Make cmux yours' webviews/src"),
      command("Started the input stress helper", "acpmux run power-input --prompt-file /tmp/brief.md"),
    ]),
  ];
  if (steers === 2)
    rows.push(
      { id: "steer-2", kind: "user", version: 1, at: at(40), text: STEER_2, steer: "landed" },
      run("steer-run-3", 42, [
        command("Listed the nightly runs", "gh run list --workflow nightly-next.yml --limit 3"),
        command("Read the latest nightly", "gh run view --log-failed", ended ? "completed" : "in_progress"),
      ]),
    );
  rows.push(
    run(`steer-run-${steers + 2}`, 50, [
      command(
        "Started the hill-climb helper",
        "acpmux run make-cmux-yours --prompt-file /tmp/brief-2.md",
        ended || steers === 2 ? "completed" : "in_progress",
      ),
    ]),
  );
  if (ended)
    rows.push(
      {
        id: "steer-answer",
        kind: "assistant",
        version: 1,
        at: at(66),
        text:
          "I started two helpers for your last two messages:\n\n" +
          "- **Power-user input stress:** fast scroll, resize, paste and workspace-switch flicks, added to the fuzzer.\n" +
          '- **Hill-climb "Make cmux yours":** three looks in the gallery for you to pick from.' +
          (steers === 2 ? "\n\nThe nightly is green, so neither waits on it." : ""),
      },
      {
        id: "steer-summary",
        kind: "turnSummary",
        version: 1,
        at: at(67),
        status: "completed",
        durationMs: 67_000,
        toolCount: steers === 2 ? 7 : 5,
      },
    );
  return rows;
}

function SteeredTurnLayouts({ steers, phase }: Props) {
  const [ended, setEnded] = useState(phase === "ended" || phase === "open");
  const [state, setState] = useState<"ready" | "running" | "folded">("ready");
  const [expanded, setExpanded] = useState<ReadonlySet<string>>(new Set());
  const timers = useRef<number[]>([]);
  useEffect(() => () => timers.current.forEach((timer) => window.clearTimeout(timer)), []);
  const rows = useMemo(
    () =>
      turnView(turnRows(steers, ended), expanded as Set<string>, {
        working: !ended,
        agentFamily: "claude",
        now: at(70),
        turnStartedAtMs: at(0),
      }),
    [steers, ended, expanded],
  );
  // gallery-capture: runs only from End the turn, which the steered-turn recorder clicks.
  const end = () => {
    timers.current.forEach((timer) => window.clearTimeout(timer));
    setEnded(false);
    setState("running");
    timers.current.push(window.setTimeout(() => setEnded(true), 900));
    timers.current.push(window.setTimeout(() => setState("folded"), 1_900));
  };
  return (
    <div className="acpmux-shell" style={{ height: "100%" }}>
      <div className="acpmux-main" data-dock="float">
        <div className="acpmux-stage">
          {phase === "run" && (
            <header className="acpmux-header">
              <button type="button" className="ui-button" data-testid="steer-end" onClick={end}>
                End the turn
              </button>
              <output data-testid="steer-state" aria-live="polite">
                {state === "folded" ? "Turn folded" : state === "running" ? "Running" : "Ready"}
              </output>
            </header>
          )}
          <VirtualTranscript
            rows={rows}
            sessionId={`steered-turn-${steers}-${phase}`}
            onToggleActivity={(id) =>
              setExpanded((open) => {
                const next = new Set(open);
                if (!next.delete(id)) next.add(id);
                return next;
              })
            }
            expanded={expanded as Set<string>}
            working={!ended}
          />
        </div>
      </div>
    </div>
  );
}

/// Opens every closed Worked for of the turn.
const openWorked: Play = async (ctx) => {
  for (let pass = 0; pass < 3; pass += 1) {
    const closed = ctx.document.querySelector<HTMLElement>(".cv-worked[aria-expanded='false']");
    if (!closed) return;
    closed.click();
    await ctx.waitFor(() => closed.getAttribute("aria-expanded") !== "false" || !closed.isConnected, {
      capMs: 5_000,
    });
  }
};

export default componentEntry<Props>({
  id: "agent-pane.steered-turn-layouts",
  title: "Steered turn layouts",
  area: "Agent pane",
  height: 900,
  covers: [
    "agent-session/acpmux/conversation/turns.ts#stackSteers",
    "agent-session/acpmux/conversation/turnFoldSteered.experiment.ts",
  ],
  experiment: { definition: turnFoldSteered, script: [{ name: "Open the turn's Worked for", run: openWorked }] },
  load: async () => SteeredTurnLayouts,
  pane: true,
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../conversation/conversation.css"),
      import("../composerControls.css"),
    ]),
  variants: {
    "one-steer-live": { props: { steers: 1, phase: "live" }, note: "One steer, live: a call in flight after it." },
    "one-steer-ended": { props: { steers: 1, phase: "ended" } },
    "one-steer-open": { props: { steers: 1, phase: "open" }, play: openWorked },
    "one-steer-run": { props: { steers: 1, phase: "run" }, note: "Live; End the turn lands the answer and folds it." },
    "two-steers-live": { props: { steers: 2, phase: "live" } },
    "two-steers-ended": { props: { steers: 2, phase: "ended" } },
    "two-steers-open": { props: { steers: 2, phase: "open" }, play: openWorked },
    "two-steers-run": { props: { steers: 2, phase: "run" }, note: "Live; End the turn lands the answer and folds it." },
  },
});
