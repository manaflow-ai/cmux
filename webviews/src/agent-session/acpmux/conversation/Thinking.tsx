// "Thinking 4s": a running turn before its first output, with the time since the prompt (`since`),
// ticking each second, so a long first think never reads as a stuck label. No mark blinks before it
// (Leo, 2026-10-20: "wtf have we removed this yet"); the word itself carries the motion, as the Codex
// and ChatGPT apps draw it: a light band in the theme accent sweeps across it (`is-shimmer`,
// conversation.css), still under Reduce Motion and the static status look. Before the turn, while
// the prompt waits for its agent to start, the same line reads the start status ("Starting Claude
// Code…") with Cancel, no time and no sweep, so the line keeps one place from send to the first
// output (cx-ncc.58). Only the status is the live region. While the chat waits on the person (an
// ask above the composer, waitingOn.ts), the line says that instead, with no time and no sweep:
// never "Thinking" while the agent is blocked on them.
import { useContext, useLayoutEffect, useState } from "react";
import { useT } from "../i18n";
import { BackgroundHint } from "./BackgroundHint";
import { useSubsessionInfo } from "../subagents/subsessions";
import { ShimmerText } from "./ShimmerText";
import { formatDuration } from "./turns";
import { WAITING_LABEL, WaitingOnContext } from "./waitingOn";
import { TurnTokens } from "./TurnTokens";
import { useTicking, WorkingCountsContext, workingParts } from "./WorkingFor";

/// How long streaming text must hold still before the live line comes back under it.
export const QUIET_MS = 1200;

/// False while `key` changed in the last `ms`, true once it held still that long (or there is none).
function useQuiet(key: string | undefined, ms = QUIET_MS): boolean {
  const [quiet, setQuiet] = useState(key === undefined);
  // The first streamed assistant chunk inserts the answer and changes `key` in the same commit.
  // Hide the live line before that commit paints; an effect would leave one frame of "Thinking"
  // underneath the first token. The timer remains an ordinary effect so it never blocks layout.
  useLayoutEffect(() => {
    if (key === undefined) {
      setQuiet(true);
      return;
    }
    setQuiet(false);
    const timer = setTimeout(() => setQuiet(true), ms);
    return () => clearTimeout(timer);
  }, [key, ms]);
  return quiet;
}

/// `doing`, `doingAt`, `doingShell`, `draft`, `untimed`, `quietKey`: the Codex-style live line at the
/// bottom of a running turn (conversation/turns.ts `codexLiveTurn`), the turn's one live block, which
/// each step replaces in place: "Thinking 18s" (the turn's time, and its tokens when the harness
/// reports them), the call in flight ("Running bun test 13s", or what it says it does, "Run the
/// web tests 13s"), the latest finished step until the next starts (`done`, "Ran grep … 15s"), or
/// "Writing a command 9s" while the agent still writes the command (`draft`). One clock and one
/// token count for all of them, the turn's, so the line just keeps going. All shimmer. While text streams (`quietKey` moves) the line keeps
/// its height but draws nothing.
export function Thinking({
  status,
  onCancel,
  since,
  now = Date.now,
  doing,
  doingAt,
  doingShell = false,
  sendTo,
  sendSession,
  draft = false,
  done = false,
  untimed = false,
  quietKey,
  below = false,
  command = false,
}: {
  status?: string;
  onCancel?: () => void;
  since?: number;
  now?: () => number;
  doing?: string;
  doingAt?: number;
  doingShell?: boolean;
  /// The call in flight sends a message to `sendTo` (the sub-session `sendSession`, by its name
  /// once the list has it): "Sending message to tests".
  sendTo?: string;
  sendSession?: string;
  draft?: boolean;
  /// `doing` is the latest step, finished ("Ran grep …"): the line holds it until the next one.
  done?: boolean;
  untimed?: boolean;
  quietKey?: string;
  /// The turn's last row (conversation/turns.ts): as tall as the footer that replaces it.
  below?: boolean;
  /// The call in flight is a command: the line offers ⌃B, as the command's own row does
  /// (BackgroundHint.tsx), since the row is not drawn while it runs.
  command?: boolean;
} = {}) {
  const t = useT();
  const waiting = useContext(WaitingOnContext);
  // The turn's time, from the prompt, whatever the line names: it keeps counting across steps and
  // never starts again at a call (Leo, 2026-11-01: "it should just keep going").
  const from = untimed ? undefined : since;
  const timed = !status && !waiting && from !== undefined;
  const time = useTicking(timed, now);
  const quiet = useQuiet(status || waiting || doing !== undefined ? undefined : quietKey);
  const sendName = useSubsessionInfo(sendSession)?.name ?? sendTo;
  const label =
    status ??
    (doing === undefined
      ? t("thinking")
      : sendName !== undefined
        ? t("send.sending", { target: sendName })
        : doingShell
          ? doing
            ? t(done ? "tools.ranCommand" : "tools.runningCommand", { command: doing })
            : draft
              ? t("tools.writingCommand")
              : t(done ? "tools.ranUnnamed" : "tools.runningUnnamed")
          : doing);
  const elapsed = timed ? formatDuration(Math.max(0, time - from)) : undefined;
  // The turn's generated output tokens so far (WorkingFor.tsx), on the line while it times the turn; and, with the
  // running tray off, the work still going in the background, each count opening what it counts
  // (App.tsx counts nothing while the tray lists it).
  const counts = useContext(WorkingCountsContext);
  const tokens = counts?.tokens;
  const showTokens = Boolean(tokens) && timed;
  const parts = counts && !status && !waiting ? workingParts(t, counts) : [];
  return (
    <div className={`cv-worked${below ? " is-below" : ""}${quiet ? "" : " is-quiet"}`} data-find-skip>
      {waiting ? (
        <output className="cv-thinking cv-waiting" data-waiting={waiting}>
          {t(WAITING_LABEL[waiting])}
        </output>
      ) : status ? (
        <output className="cv-thinking">{label}</output>
      ) : (
        <span className="cv-shimmer__row">
          <output className="cv-thinking is-shimmer">
            <ShimmerText
              text={label}
              baseText={label}
              lit={
                <>
                  <span className="cv-shimmer__lit-label" data-text={label} />
                  {elapsed && <span className="cv-shimmer__lit-time" data-text={elapsed} />}
                </>
              }
            />
          </output>
          {elapsed && <span className="cv-worked__time">{elapsed}</span>}
        </span>
      )}
      {showTokens && (
        <span className="cv-worked__count">
          <span className="cv-worked__sep" aria-hidden="true">
            ·
          </span>
          <TurnTokens total={tokens} split={counts?.split} />
        </span>
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
      {/* Keyed by the call, so each command's hint waits its moment again. */}
      {command && !done && !waiting && doing !== undefined && <BackgroundHint key={doingAt} />}
      {status && onCancel && (
        <button type="button" className="cv-thinking__cancel" onClick={onCancel}>
          {t("switch.cancelPrompt")}
        </button>
      )}
    </div>
  );
}
