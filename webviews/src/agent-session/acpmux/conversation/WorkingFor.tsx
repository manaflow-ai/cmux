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
// the tray above the composer is the count, and App.tsx counts nothing here. Token usage stays in
// the usage details. Over the work it is the turn's header in its running phase, a `worked`
// row (turns.ts `turnHeaderId`, rows/WorkedRow.tsx): when the turn ends, the same row reads "Worked for". While the
// turn waits on the person (an ask
// above the composer, waitingOn.ts), the line says so in place of the time and the call: the clock
// would read as the agent still working.
//
// Drawn as the turn's last row (`row.below`), it has no rule under it and its clock never stops while the turn runs, and before any output
// (`row.thinkingNow`) it reads "Thinking" beside the time.
import { useContext, useMemo } from "react";
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { usePageNow as useTicking } from "../../../ui/pageClock";
import { ChevronRight, TerminalSquare } from "./icons";
import { useTextSwap } from "../../../ui/motion/useTextSwap";
import { BackgroundHint } from "./BackgroundHint";
import { TimedLabel } from "./TurnTokens";
import { useTranscriptDisclosure } from "./transcriptDisclosureModel";
import { formatDuration } from "./turns";
import { useSubsessionInfo } from "../subagents/subsessions";
import { WAITING_LABEL, WaitingOnContext } from "./waitingOn";
import { StatusVerb } from "./StatusVerb";
import { workingParts, WorkingCountsContext } from "./workingForModel";
/// Over the work (`row.below` false), `onToggle` opens and closes the running turn's work under the
/// key its "Worked for" takes when it ends (turns.ts `shapeLiveRows`, #50987): the label is the toggle,
/// with the chevron "Worked for" draws, and the counts stay buttons of their own beside it.
export function WorkingFor({
  row,
  now = Date.now,
  expanded = false,
  onToggle,
}: {
  row: AcpmuxRow;
  now?: () => number;
  expanded?: boolean;
  onToggle?: () => void;
}) {
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
  const toggles = onToggle !== undefined && !row.below;
  const label = (
    <>
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
          {until - row.at < 1000 ? (
            t("subsession.state.working")
          ) : (
            <TimedLabel
              text={(time) => t("turn.working", { time })}
              time={Math.max(0, until - row.at)}
              ticking={!held}
            />
          )}
        </span>
      )}
    </>
  );
  return (
    // Find counts and visits transcript rows only (chatFind.ts findMatches skips this row), so the
    // line is not painted either: the call it names is matched on its own tool row.
    // Over the work (turns.ts `shapeLiveTurn`) it keeps the closed "Worked for" line's box, rule and
    // room (`is-toggle`, conversation.css), so the turn's end swaps the words and nothing moves.
    <div className={row.below ? "cv-worked is-below" : "cv-worked has-divider is-toggle"} data-find-skip>
      {toggles ? (
        <button type="button" className="cv-worked__toggle" aria-expanded={expanded} onClick={onToggle}>
          {label}
          <ChevronRight size={14} className={`cv-worked__chevron cv-rotor${expanded ? " is-open" : ""}`} />
        </button>
      ) : (
        label
      )}
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
      {/* Over the work it is the turn's header in its running phase (turns.ts `turnHeaderId`): the
          ended "Worked for"'s chevron has its slot already, right after the words as it draws
          there, unseen until the turn ends and the line opens what it folded. */}
      {!row.below && <ChevronRight size={14} className="cv-worked__chevron cv-rotor is-reserved" aria-hidden="true" />}
    </div>
  );
}
