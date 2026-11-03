// "Thinking 4s": a running turn before its first output, with the time since the prompt (`since`),
// ticking each second, so a long first think never reads as a stuck label. No mark blinks before it
// (Leo, 2026-10-20: "wtf have we removed this yet"); the word itself carries the motion, as the Codex
// and ChatGPT apps draw it: a light band in the theme accent sweeps across it (`is-shimmer`,
// conversation.css), still under Reduce Motion and the static status look. Before the turn, while
// the prompt waits for its agent to start, the same line already reads "Thinking", with no start
// status and no Cancel (Leo, 2026-11-01), so the line keeps one place and one look from send to
// the first output (cx-ncc.58). Only the status is the live region. While the chat waits on the person (an
// ask above the composer, waitingOn.ts), the line says that instead, with no time and no sweep:
// never "Thinking" while the agent is blocked on them.
import { useContext, useLayoutEffect, useState } from "react";
import { experimentArm } from "../../../experiments/experiment";
import { usePaneLanguage, useT } from "../i18n";
import { agentStartLook } from "./agentStart.experiment";
import { liveLineTokens } from "./liveLineTokens.experiment";
import { Spinner } from "./icons";
import { BackgroundHint } from "./BackgroundHint";
import { useSubsessionInfo } from "../subagents/subsessions";
import { ShimmerText } from "./ShimmerText";
import { formatDuration } from "./turns";
import { WAITING_LABEL, WaitingOnContext } from "./waitingOn";
import { compactTokens, hasTokens, tokenDetail, TurnTokens } from "./TurnTokens";
import { verbLeads } from "./ToolVerb";
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

/// The live line's words split as Claude Code draws them: the action in full ink ("Using repo",
/// "Running", "Sending"), the rest muted (": repo grep", " bun test"). An MCP call's action runs to
/// its server's colon (`call`: the line names a call, not a command or a send); any other line's is
/// its first word. Undefined when the line is one word, or in a language whose verb does not lead.
export function liveLead(label: string, leads: boolean, call: boolean): { lead: string; rest: string } | undefined {
  if (!leads) return undefined;
  const server = call ? /^(\p{L}+ [^\s:]+)(: \S[\s\S]*)$/u.exec(label) : null;
  if (server) return { lead: server[1]!, rest: server[2]! };
  const word = /^(\p{L}+)( \S[\s\S]*)$/u.exec(label);
  return word ? { lead: word[1]!, rest: word[2]! } : undefined;
}

/// `doing`, `doingAt`, `doingShell`, `draft`, `untimed`, `quietKey`: the Codex-style live line at the
/// bottom of a running turn (conversation/turns.ts `codexLiveTurn`), the turn's one live block, which
/// each step replaces in place: "Thinking 18s" (the turn's time, and its tokens when the harness
/// reports them), the call in flight ("Running bun test 13s", or what it says it does, "Run the
/// web tests 13s"), the latest finished step until the next starts (`done`, "Ran grep … 15s"), or
/// "Writing a command 9s" while the agent still writes the command (`draft`). One clock and one
/// token count for all of them, the turn's, so the line just keeps going: "Using repo: repo grep 3m 2s ·
/// 47.4K tokens", as Claude Code desktop's live line reads, with no mark before it: the shimmer is
/// its only working sign (Leo, 2026-11-03: "we don't want the claude symbol ellipsis thing btw we
/// just keep the shimmer ONLY"). All shimmer. While text streams (`quietKey` moves) the line keeps
/// its height but draws nothing.
export function Thinking({
  starting = false,
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
  /// The prompt waits for its agent to start (harnessSwitch.ts): the start look's arm draws it.
  starting?: boolean;
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
  const language = usePaneLanguage();
  const waiting = useContext(WaitingOnContext);
  const startLook = starting && !waiting ? experimentArm(agentStartLook) : "thinking";
  // The turn's time, from the prompt, whatever the line names: it keeps counting across steps and
  // never starts again at a call (Leo, 2026-11-01: "it should just keep going").
  const from = untimed ? undefined : since;
  const timed = !waiting && from !== undefined;
  const time = useTicking(timed, now);
  const quiet = useQuiet(waiting || doing !== undefined ? undefined : quietKey);
  const sendName = useSubsessionInfo(sendSession)?.name ?? sendTo;
  const label =
    doing === undefined
      ? t("thinking")
      : sendName !== undefined
        ? t("send.sending", { target: sendName })
        : doingShell
          ? doing
            ? t(done ? "tools.ranCommand" : "tools.runningCommand", { command: doing })
            : draft
              ? t("tools.writingCommand")
              : t(done ? "tools.ranUnnamed" : "tools.runningUnnamed")
          : doing;
  const lead = doing === undefined ? undefined : liveLead(label, verbLeads(t), !doingShell && sendName === undefined);
  const elapsed = timed ? formatDuration(Math.max(0, time - from)) : undefined;
  // The turn's generated output tokens so far (WorkingFor.tsx), on the line while it times the turn; and, with the
  // running tray off, the work still going in the background, each count opening what it counts
  // (App.tsx counts nothing while the tray lists it).
  const counts = useContext(WorkingCountsContext);
  const tokens = counts?.tokens;
  // A send's line names who it goes to and for how long; the turn's token counts there are noise
  // (Leo, 2026-11-02, on "Sending message to … 3m 56s · ↓1.4K out ↑819.5K in" among the message
  // rows: "i also think this is quite weird looking").
  const sending = doing !== undefined && sendName !== undefined;
  const showTokens = Boolean(tokens) && timed && !sending;
  // One count, as Claude Code's live line says it ("47.4K tokens"): the turn's output, with the
  // split on hover (liveLineTokens.experiment.ts). Never "↓ out ↑ in" in the line's words (the
  // coordinator, relaying Leo's capture of "Thinking 7m 34s · ↓ 4.5K out ↑ 1.4M in").
  const oneCount = experimentArm(liveLineTokens) === "total";
  const parts = counts && !waiting ? workingParts(t, counts) : [];
  // The `silent` and `spinner` start looks keep the line's box (`.cv-worked`'s height) with no words.
  if (startLook !== "thinking")
    return (
      <div
        className={`cv-worked${below ? " is-below" : ""}${startLook === "silent" ? " is-quiet" : ""}`}
        data-find-skip
      >
        {startLook === "spinner" && <Spinner size={14} loading />}
      </div>
    );
  return (
    // `cv-worked--live`: its words start on the icon rows' text column (conversation.css).
    <div className={`cv-worked cv-worked--live${below ? " is-below" : ""}${quiet ? "" : " is-quiet"}`} data-find-skip>
      {waiting ? (
        <output className="cv-thinking cv-waiting" data-waiting={waiting}>
          {t(WAITING_LABEL[waiting])}
        </output>
      ) : (
        <span className="cv-shimmer__row">
          <output className="cv-thinking is-shimmer">
            <ShimmerText
              text={label}
              baseText={
                lead ? (
                  <>
                    <span className="cv-worked__lead">{lead.lead}</span>
                    {lead.rest}
                  </>
                ) : (
                  label
                )
              }
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
          {oneCount && tokens ? (
            <span
              className="cv-worked__tokens"
              title={hasTokens(counts?.split) ? tokenDetail(t, language, counts.split) : undefined}
            >
              {t("turn.working.tokens", { n: tokens, tokens: compactTokens(language, tokens) })}
            </span>
          ) : (
            <TurnTokens total={tokens} split={counts?.split} />
          )}
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
    </div>
  );
}
