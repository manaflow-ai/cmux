// The older "Working for" line over a running turn's work (a `working` row; the transcript now
// draws the turn's one live line at its bottom instead, Thinking.tsx): "Working for 42s", ticking each second from the prompt,
// or held at `durationMs` while text streams. While a call runs (`row.doing`, turns.ts) it names
// that call beside the time instead, as Claude desktop's line does, after the terminal glyph when
// the call is a command; not while the call's own tool row is on screen, which names it already.
// No mark blinks before it; the ticking time says the turn is alive. The running tray above the
// composer counts the work still going in the background (subagents/runningTray.ts), never this
// line. After the time, as Claude desktop's line does, it says the turn's generated output so far
// ("5m 54s · 2.1M out") when the harness reports it (direct.ts `turnTokens`). When the turn
// ends, the "Worked for" disclosure takes its place. While the turn waits on the person (an ask
// above the composer, waitingOn.ts), the line says so in place of the time and the call: the clock
// would read as the agent still working.
//
// Drawn as the turn's last row (`row.below`), it has no rule under it and its clock never stops while the turn runs, and before any output
// (`row.thinkingNow`) it reads "Thinking" beside the time.
import { createContext, useContext } from "react";
import { type Translate, useT } from "../i18n";
import type { AcpmuxRow, TurnTokenSplit } from "../model";
import { usePageNow as useTicking } from "../../../ui/pageClock";
export { usePageNow as useTicking } from "../../../ui/pageClock";
import { TerminalSquare } from "./icons";
import { BackgroundHint } from "./BackgroundHint";
import { TimedLabel, TurnTokens } from "./TurnTokens";
import { useTranscriptDisclosure } from "./transcriptDisclosure";
import { formatDuration } from "./turns";
import { useSubsessionInfo } from "../subagents/subsessions";
import { WAITING_LABEL, WaitingOnContext } from "./waitingOn";
import { StatusVerb } from "./StatusVerb";

export const workingLabel = (t: Translate, at: number, now: number) =>
  t("turn.working", { time: formatDuration(Math.max(0, now - at)) });

/// What the running turn's line says after its time (App.tsx). The running subagents, background
/// commands and started chats are the tray's to count (subagents/runningTray.ts), never the line's.
export type WorkingCounts = {
  /// The turn's generated output tokens so far (snapshot `turnTokens`), when the harness reports them.
  tokens?: number;
  /// Those tokens split into output and what the calls read (snapshot `turnTokenSplit`), when known.
  split?: TurnTokenSplit;
};

export { workingTokens } from "./TurnTokens";

export const WorkingCountsContext = createContext<WorkingCounts | undefined>(undefined);

export function WorkingFor({ row, now = Date.now }: { row: AcpmuxRow; now?: () => number }) {
  const t = useT();
  const counts = useContext(WorkingCountsContext);
  const waiting = useContext(WaitingOnContext);
  const held = !row.below && row.durationMs !== undefined;
  // No tick while the line waits on the person: it shows no time.
  const time = useTicking(!held && waiting === undefined, now);
  const until = held ? row.at + row.durationMs! : time;
  // While the call's group is open, its own row under the line names it (turns.ts `ownRow`).
  // The Verbose transcript view opens every group, as ToolGroupRow reads it.
  const [groupOpen] = useTranscriptDisclosure(row.doingGroup ?? "", row.doingGroupOpen === true, true);
  const shown = row.doingGroup && groupOpen ? undefined : row.doing;
  // A send in flight names who it goes to, not its command (acpmuxSends.ts, turns.ts `sendingTo`).
  const sendName = useSubsessionInfo(row.doingSendSession)?.name ?? row.doingSendTo;
  const sending = shown !== undefined && sendName !== undefined;
  const doing = sending ? t("send.sending", { target: sendName }) : shown;
  return (
    // Find counts and visits transcript rows only (chatFind.ts findMatches skips this row), so the
    // line is not painted either: the call it names is matched on its own tool row.
    <div className={row.below ? "cv-worked is-below" : "cv-worked has-divider"} data-find-skip>
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
          <span className={doing ? "cv-worked__label cv-worked__doing" : "cv-worked__label"}>
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
      {counts?.tokens ? (
        <span className="cv-worked__count">
          <span className="cv-worked__sep" aria-hidden="true">
            ·
          </span>
          <TurnTokens total={counts.tokens} split={counts.split} />
        </span>
      ) : null}
      {/* A running command's ⌃B hint (BackgroundHint.tsx): on the line, never on its row. Keyed by
          the call, so each command's hint waits its moment again. */}
      {!waiting && row.doingCommand && !row.doingDraft && <BackgroundHint key={row.doing} />}
    </div>
  );
}
