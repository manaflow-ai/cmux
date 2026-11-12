// The older "Working for" line over a running turn's work (a `working` row; the transcript now
// draws the turn's one live line at its bottom instead, Thinking.tsx, with the same counts): "Working for 42s", ticking each second from the prompt,
// or held at `durationMs` while text streams. While a call runs (`row.doing`, turns.ts) it names
// that call beside the time instead, as Claude desktop's line does, after the terminal glyph when
// the call is a command; not while the call's own tool row is on screen, which names it already.
// No mark blinks before it; the ticking time says the turn is alive. After
// that it counts the work still going in the background, as Claude's phone app does ("Working… · 5
// running tasks"): "· 3 subagents · 1 command", only subagents and chats the agent started still
// running (one word, subagents, as the tray says), and background commands that have not ended
// (the process registry's and the transcript's, session-info/processes.ts `backgroundCommands`). Each count opens what it
// counts. The counts follow on the same fixed-height line, so one that comes or goes moves neither
// the label nor the rows below. With the running tray on (the default, subagents/runningTray.ts)
// the tray above the composer is the count, and App.tsx counts nothing here. Before them, as Claude
// desktop's line does, it says the turn's generated output so far
// ("5m 54s · 2.1M out") when the harness reports it (direct.ts `turnTokens`). When the turn
// ends, the "Worked for" disclosure takes its place. While the turn waits on the person (an ask
// above the composer, waitingOn.ts), the line says so in place of the time and the call: the clock
// would read as the agent still working.
//
// Drawn as the turn's last row (`row.below`), it has no rule under it and its clock never stops while the turn runs, and before any output
// (`row.thinkingNow`) it reads "Thinking" beside the time.
import { useContext, useMemo } from "react";
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { usePageNow as useTicking } from "../../../ui/pageClock";
import { TerminalSquare } from "./icons";
import { useTextSwap } from "../../../ui/motion/useTextSwap";
import { BackgroundHint } from "./BackgroundHint";
import { TimedLabel, TurnTokens } from "./TurnTokens";
import { useTranscriptDisclosure } from "./transcriptDisclosureModel";
import { formatDuration } from "./turns";
import { useSubsessionInfo } from "../subagents/subsessions";
import { WAITING_LABEL, WaitingOnContext } from "./waitingOn";
import { StatusVerb } from "./StatusVerb";
import { workingParts, WorkingCountsContext } from "./workingForModel";
export function WorkingFor({ row, now = Date.now }: { row: AcpmuxRow; now?: () => number }) {
  const t = useT();
  const counts = useContext(WorkingCountsContext);
  const waiting = useContext(WaitingOnContext);
  const held = !row.below && row.durationMs !== undefined;
  // No tick while the line waits on the person: it shows no time.
  const time = useTicking(!held && waiting === undefined, now);
  const until = held ? row.at + row.durationMs! : time;
  // While the call's group is open, its own row under the line names it (turns.ts `ownRow`).
  // The Verbose transcript view opens every group, as ToolGroupRow reads it, and the group follows
  // its run's line as its own line does (TurnRows.tsx `groupNode`): a run line the reader closed
  // closes the group, so the line names the call the closed group no longer shows.
  const runLine = useMemo(() => (row.doingRun ? [row.doingRun] : undefined), [row.doingRun]);
  const [groupOpen] = useTranscriptDisclosure(row.doingGroup ?? "", row.doingGroupOpen === true, true, {
    inherits: runLine,
    closedBy: runLine,
  });
  const shown = row.doingGroup && groupOpen ? undefined : row.doing;
  // A send in flight names who it goes to, not its command (acpmuxSends.ts, turns.ts `sendingTo`).
  const sendName = useSubsessionInfo(row.doingSendSession)?.name ?? row.doingSendTo;
  const sending = shown !== undefined && sendName !== undefined;
  const doing = sending ? t("send.sending", { target: sendName }) : shown;
  const parts = counts ? workingParts(t, counts) : [];
  // A new call changes the words as Claude desktop's line does (ui/motion/useTextSwap.ts).
  const words = useTextSwap<HTMLSpanElement>(waiting ? undefined : (doing ?? ""));
  return (
    // Find counts and visits transcript rows only (chatFind.ts findMatches skips this row), so the
    // line is not painted either: the call it names is matched on its own tool row.
    // Over the work (turns.ts `shapeLiveTurn`) it keeps the closed "Worked for" line's box, rule and
    // room (`is-toggle`, conversation.css), so the turn's end swaps the words and nothing moves.
    <div className={row.below ? "cv-worked is-below" : "cv-worked has-divider is-toggle"} data-find-skip>
      {!waiting && doing && row.doingCommand && !sending && (
        <span className="cv-worked__glyph" aria-hidden="true">
          <TerminalSquare />
        </span>
      )}
      {waiting ? (
        <output className="cv-worked__label cv-waiting" data-waiting={waiting}>
          {t(WAITING_LABEL[waiting])}
        </output>
      ) : doing || row.thinkingNow ? (
        <>
          <span ref={words} className={doing ? "cv-worked__label cv-worked__doing" : "cv-worked__label"}>
            {doing ??
              (held ? t("thinking") : <StatusVerb elapsedMs={Math.max(0, until - row.at)} verbKey={row.verbKey} />)}
          </span>
          <span className="cv-worked__time">{formatDuration(Math.max(0, until - row.at))}</span>
        </>
      ) : (
        <span className="cv-worked__label">
          <TimedLabel text={(time) => t("turn.working", { time })} time={Math.max(0, until - row.at)} />
        </span>
      )}
      {/* Over the work it says only the turn's time, as the Codex app's "Working for 32s". */}
      {row.below && counts?.tokens ? (
        <span className="cv-worked__count">
          <span className="cv-worked__sep" aria-hidden="true">
            ·
          </span>
          <TurnTokens total={counts.tokens} split={counts.split} />
        </span>
      ) : null}
      {parts.map((part) => (
        <span key={part.key} className="cv-worked__count">
          <span className="cv-worked__sep" aria-hidden="true">
            ·
          </span>
          <button type="button" className="cv-worked__open" onClick={part.open}>
            {part.label}
          </button>
        </span>
      ))}
      {/* A running command's ⌃B hint (BackgroundHint.tsx): on the line, never on its row. Keyed by
          the call, so each command's hint waits its moment again. */}
      {!waiting && row.doingCommand && !row.doingDraft && <BackgroundHint key={row.doing} />}
    </div>
  );
}
