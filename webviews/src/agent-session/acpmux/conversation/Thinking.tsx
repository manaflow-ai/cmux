// "Thinking 4s": a running turn before its first output, with the time since the prompt (`since`),
// ticking each second, so a long first think never reads as a stuck label. No mark blinks before it
// (Leo, 2026-10-20: "wtf have we removed this yet"); the word itself carries the motion, as the Codex
// and ChatGPT apps draw it: a light band in the theme accent sweeps across it (`is-shimmer`,
// conversation.css), still under Reduce Motion and the static status look. Before the turn, while
// the prompt waits for its agent to start, the same line already reads "Thinking", with no start
// status and no Cancel (Leo, 2026-11-01), so the line keeps one place and one look from send to
// the first output (cx-ncc.58). Only the status is the live region. While the chat waits on the person (an
// ask above the composer, waitingOn.ts), the line says that instead, with no time and no sweep:
// never "Thinking" while the agent is blocked on them. It reads as Claude desktop's "Needs your input"
// pill: the attention dot and the words on a tinted pill. Once answered, the dot shrinks into the
// Thinking line that takes its place (Leo, 2026-11-05: "there's a little animation that plays. It,
// like, shrinks the thing, the circle into the Thinking... portion afterwards which is cute").
import { useContext, useLayoutEffect, useMemo, useRef, useState } from "react";
import { experimentArm } from "../../../experiments/experiment";
import { usePaneLanguage, useT } from "../i18n";
import { agentStartLook } from "./agentStart.experiment";
import { liveLineTokens } from "./liveLineTokens.experiment";
import { Spinner } from "./icons";
import { BackgroundHint } from "./BackgroundHint";
import { useSubsessionInfo } from "../subagents/subsessions";
import { ShimmerText } from "./ShimmerText";
import { formatDuration } from "./turns";
import { WAITING_LABEL, type WaitingOn, WaitingOnContext } from "./waitingOn";
import { compactTokens, hasTokens, tokenDetail, TurnTokens } from "./TurnTokens";
import { verbLeads } from "./ToolVerb";
import { useTicking, WorkingCountsContext, workingParts } from "./WorkingFor";
import { statusVerbAt, statusVerbLabels, useStatusVerbConfig } from "../statusVerbs";
import { thinkingVerb, ThinkingVerbsContext } from "./thinkingVerbs";
import type { AcpmuxTurnRetry } from "../model";
import type { Translate } from "../i18n";

/// A rate limit or an overloaded model: the model answered and is busy, not out of reach.
const BUSY = /\b(?:rate.?limit|overloaded|too many requests|capacity)\b/i;

/// What the live line says while the harness retries a failed model request (acpmux
/// `turn_retrying`): the cause in plain words, the retry's count, and the harness's error when it
/// names one ("Can't reach the model · retrying (7 of 10) · 503 server error"). Calm: no sweep and
/// no clock, since nothing works on the reply while it waits.
export function retryParts(t: Translate, retry: AcpmuxTurnRetry): { label: string; count: string; error?: string } {
  const words = retry.error?.replaceAll("_", " ");
  const busy = retry.errorStatus === 429 || retry.errorStatus === 529 || BUSY.test(words ?? "");
  const label = t(busy ? "turn.live.retry.busy" : "turn.live.retry.unreachable");
  const count =
    retry.attempt === undefined
      ? t("turn.live.retry.retrying")
      : retry.maxRetries === undefined
        ? t("turn.live.retry.attemptOnly", { attempt: retry.attempt })
        : t("turn.live.retry.attempt", { attempt: retry.attempt, max: retry.maxRetries });
  const error = [retry.errorStatus, words].filter((part) => part !== undefined && part !== "").join(" ");
  return { label, count, ...(error && { error }) };
}

/// How long a paused answer still reads "Writing"; a longer pause is the agent thinking again.
export const WRITING_MS = 5000;

/// False while `key` changed in the last `ms`, true once it held still that long (or there is none).
/// `since`, when known, is when the key's text was written: a key that was already that old when the
/// line mounted (a chat opened long after its reply paused) is quiet from the first frame, instead
/// of counting `ms` from the mount as if it had just moved.
function useQuiet(key: string | undefined, ms: number, since?: number, now: () => number = Date.now): boolean {
  const age = () => (since === undefined ? 0 : Math.max(0, now() - since));
  const [quiet, setQuiet] = useState(() => key === undefined || age() >= ms);
  // The key the line mounted with: only that one is timed from `since`; a later key just moved.
  const mounted = useRef(key);
  // The first streamed assistant chunk inserts the answer and changes `key` in the same commit.
  // The line reads "Writing" before that commit paints; an effect would leave one frame of
  // "Thinking" under the first token. The timer remains an ordinary effect so it never blocks layout.
  useLayoutEffect(() => {
    if (key === undefined) {
      setQuiet(true);
      return;
    }
    const left = key === mounted.current ? ms - age() : ms;
    if (left <= 0) {
      setQuiet(true);
      return;
    }
    setQuiet(false);
    const timer = setTimeout(() => setQuiet(true), left);
    return () => clearTimeout(timer);
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- `since` only seeds the mounted key
  }, [key, ms]);
  return quiet;
}

/// The words the live line said before its latest change, and how many changes it has rolled.
type Roll = { key?: string; label: string; lead?: { lead: string; rest: string }; turns: number; out?: Roll };

/// The live line rolls its words when they change (Leo, 2026-11-05, on another app's status line:
/// "this is quite good too how it animates the changing text!!! we need to have that!!! for
/// changing tool calls at the bottom"): the old words rise and fade out above as the new rise in
/// from below (conversation.css `cv-roll-*`). `key` names what the line says; the playful verb's
/// own rotation keeps one key, so only a new call or state rolls. Undefined (the line waits on the
/// person, retries or shows a start look) rolls nothing, and neither do the first words after it.
function useRoll(key: string | undefined, label: string, lead: Roll["lead"]): Roll {
  const [roll, setRoll] = useState<Roll>({ key, label, lead, turns: 0 });
  if (key !== roll.key) {
    const rolls = key !== undefined && roll.key !== undefined;
    setRoll({
      key,
      label,
      lead,
      // Away clears the count too: the words that come back draw no roll in.
      turns: key === undefined ? 0 : roll.turns + (rolls ? 1 : 0),
      out: rolls ? { ...roll, out: undefined } : undefined,
    });
  } else if (label !== roll.label) setRoll({ ...roll, label, lead });
  return roll;
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
/// "Writing a command 9s" while the agent still writes the command (`draft`). With no call it names
/// what the turn does instead: "Waiting on 2 subagents", "Writing", else "Thinking" (`liveState`).
/// One clock and one token count for all of them, the turn's, so the line just keeps going: "Using
/// repo: repo grep 3m 2s · 47.4K tokens", as Claude Code desktop's live line reads, with no mark
/// before it: the shimmer is its only working sign (Leo, 2026-11-03: "we don't want the claude
/// symbol ellipsis thing btw we just keep the shimmer ONLY"). Past the turn's first step
/// (`turnTotal`) that clock follows a finished step's own time after a dot ("2s · 4m"), so a long
/// wait never reads as that long a think or call. All shimmer. While text streams (`quietKey` moves) the
/// line stays where it is and reads "Writing": it never leaves and comes back mid-turn (Leo,
/// 2026-11-04: "it appears and disappears????").
/// The longest the answered dot stays, should its shrink never end (motion off draws no animation).
const SETTLE_MS = 400;

/// True from the render the chat stops waiting on the person until the dot's shrink ends (`done`)
/// or SETTLE_MS passes: the line draws the shrinking dot before its words for that long.
function useAnswered(waiting: WaitingOn | undefined): [boolean, () => void] {
  const [answered, setAnswered] = useState(false);
  const was = useRef(waiting);
  useLayoutEffect(() => {
    const before = was.current;
    was.current = waiting;
    if (waiting || !before) {
      setAnswered(false);
      return;
    }
    setAnswered(true);
    const timer = setTimeout(() => setAnswered(false), SETTLE_MS);
    return () => clearTimeout(timer);
  }, [waiting]);
  return [answered, () => setAnswered(false)];
}

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
  doneMs,
  liveState,
  liveAgents = 0,
  thoughtMs,
  turnTotal = false,
  untimed = false,
  verbKey,
  quietKey,
  quietAt,
  below = false,
  command = false,
  retry,
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
  /// How long that finished step took (turns.ts `liftedStep`): the time beside it with `turnTotal`.
  doneMs?: number;
  /// With no call named: the agent waits on `liveAgents` foreground subagents, or writes its reply
  /// (turns.ts `codexLiveTurn`). Otherwise it reads "Thinking".
  liveState?: "subagents" | "writing";
  liveAgents?: number;
  /// "Thinking" past the first step: the turn's summed thinking time, shown beside the word.
  thoughtMs?: number;
  /// Past the turn's first step the clock reads as the turn's whole time ("2s · 4m"), after the
  /// finished step's own time when it has one, so no wait reads as that long a think or call.
  turnTotal?: boolean;
  untimed?: boolean;
  /// The turn's prompt id, used to keep one playful verb for the whole turn when Rotate is on.
  verbKey?: string;
  quietKey?: string;
  /// When the reply `quietKey` names was written (turns.ts `codexLiveTurn`): a reply already
  /// still past WRITING_MS when the line mounts reads "Thinking" at once.
  quietAt?: number;
  /// The turn's last row (conversation/turns.ts): as tall as the footer that replaces it.
  below?: boolean;
  /// The call in flight is a command: the line offers ⌃B, as the command's own row does
  /// (BackgroundHint.tsx), since the row is not drawn while it runs.
  command?: boolean;
  /// The harness retries a failed model request (acpmux `turn_retrying`): the line says that,
  /// never "Thinking" (`retryParts`).
  retry?: AcpmuxTurnRetry;
} = {}) {
  const t = useT();
  const language = usePaneLanguage();
  const waiting = useContext(WaitingOnContext);
  const [answered, settled] = useAnswered(waiting);
  const startLook = starting && !waiting ? experimentArm(agentStartLook) : "thinking";
  // The turn's time, from the prompt, whatever the line names: it keeps counting across steps and
  // never starts again at a call (Leo, 2026-11-01: "it should just keep going").
  const from = untimed ? undefined : since;
  const timed = !waiting && from !== undefined;
  const time = useTicking(timed, now);
  const statusVerbConfig = useStatusVerbConfig();
  const thinkingVerbs = useContext(ThinkingVerbsContext);
  const verbs = useMemo(
    () => thinkingVerbs ?? statusVerbLabels(t, statusVerbConfig),
    [t, statusVerbConfig, thinkingVerbs],
  );
  // CSS sizes both shimmer layers from these inert samples once, not by measuring on each tick.
  const verbSizes = useMemo(
    () =>
      verbs.map((word, index) => (
        <span key={index} className="cv-status-verb__size" data-text={word} aria-hidden="true" inert />
      )),
    [verbs],
  );
  // A reply that paused only a moment is still being written; one silent for longer is the agent
  // thinking before its next step, which reads "Thinking" (Leo, 2026-11-03).
  const stillWriting = !useQuiet(liveState === "writing" ? quietKey : undefined, WRITING_MS, quietAt, now);
  const sendName = useSubsessionInfo(sendSession)?.name ?? sendTo;
  const waitsOnAgents = liveState === "subagents" && liveAgents > 0;
  const writing = liveState === "writing" && stillWriting;
  const elapsedMs = timed ? Math.max(0, time - from) : 0;
  const turnVerb = thinkingVerb(thinkingVerbs, verbKey);
  const decorative = doing === undefined && !waitsOnAgents && !writing;
  const label =
    doing === undefined
      ? waitsOnAgents
        ? t("turn.live.waitingOnSubagents", { n: liveAgents })
        : writing
          ? t("turn.live.writing")
          : (turnVerb ??
            (statusVerbConfig.mode === "custom" ? statusVerbAt(elapsedMs, { mode: "custom", verbs }) : t("thinking")))
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
  // A retry or a start look draws other words in place of the line: coming back rolls nothing.
  const away = waiting !== undefined || retry !== undefined || startLook !== "thinking";
  const roll = useRoll(away ? undefined : decorative ? "" : label, label, lead);
  const turnTime = timed ? formatDuration(Math.max(0, time - from)) : undefined;
  // Past the first step a finished step's own time stands beside the label, and the turn's clock
  // follows it after a dot: "Ran grep -n x 2s · 15s" (Leo, 2026-11-03: "i think the "thinking"
  // accounting is also off pretty frequently"). With no own time the turn's clock stands beside the
  // label alone, "Waiting on 2 subagents 1h 24m", never after a dot, and no line says "total" (Leo,
  // 2026-11-04: "the total is redundant", "there's no point to say total", and on the dot's gap:
  // "same here it's annoying to look at"). The turn's clock stays its own element (`cv-worked__time`)
  // that keeps ticking from the prompt.
  const total = turnTotal && turnTime !== undefined;
  // What stands beside the label then, never a clock that starts again at a call (Leo, 2026-11-01:
  // "it should just keep going"): a finished step's own start to end, or the turn's summed thinking.
  const ownMs = doing === undefined ? (waitsOnAgents || writing ? undefined : thoughtMs) : done ? doneMs : undefined;
  const own = total && ownMs !== undefined ? formatDuration(ownMs) : undefined;
  const elapsed = own ?? turnTime;
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
  // The label already names the subagents it waits on: no second count of them.
  const parts = (counts && !waiting ? workingParts(t, counts) : []).filter(
    (part) => !(liveState === "subagents" && part.key === "agents"),
  );
  // A model the harness cannot reach: said calmly in the line's own box, so nothing moves when it
  // starts or ends (Leo, 2026-11-03). What the chat waits on the person for still comes first.
  if (retry && !waiting) {
    const parts = retryParts(t, retry);
    return (
      <div
        className={`cv-worked cv-worked--live${below ? " is-below" : ""}`}
        data-find-skip
        data-lead-slot
        data-retrying=""
      >
        <output className="cv-thinking cv-retrying">{parts.label}</output>
        <span className="cv-worked__count">
          <span className="cv-worked__sep" aria-hidden="true">
            ·
          </span>
          {parts.count}
        </span>
        {parts.error && (
          <span className="cv-worked__count cv-retrying__error" title={parts.error}>
            <span className="cv-worked__sep" aria-hidden="true">
              ·
            </span>
            <span className="cv-retrying__words">{parts.error}</span>
          </span>
        )}
      </div>
    );
  }
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
    // `cv-worked--live`: its words start on the icon column, with no icon slot (conversation.css).
    <div className={`cv-worked cv-worked--live${below ? " is-below" : ""}`} data-find-skip>
      {waiting ? (
        <output className="cv-thinking cv-waiting" data-waiting={waiting}>
          <span className="cv-needs-input-glyph" aria-hidden="true" />
          <span className="cv-waiting__pill">{t(WAITING_LABEL[waiting])}</span>
        </output>
      ) : (
        <span className="cv-shimmer__row">
          {answered && (
            <span className="cv-needs-input-glyph is-answered" aria-hidden="true" onAnimationEnd={settled} />
          )}
          {/* The words before, rolling out above: drawn from attributes, so no reader, Find or copy
              meets them twice (conversation.css `cv-roll-out`); keyed by the change, so each rolls. */}
          {roll.out && (
            <span
              key={roll.turns}
              className="cv-roll-out"
              aria-hidden="true"
              inert
              data-lead={roll.out.lead?.lead}
              data-text={roll.out.lead ? roll.out.lead.rest : roll.out.label}
            />
          )}
          <output
            className="cv-thinking is-shimmer"
            data-roll={roll.turns === 0 ? undefined : roll.turns % 2 ? "odd" : "even"}
            aria-label={decorative ? t("thinking") : undefined}
            aria-live={decorative ? "off" : undefined}
          >
            <ShimmerText
              text={label}
              baseText={
                lead ? (
                  <>
                    <span className="cv-worked__lead">{lead.lead}</span>
                    {lead.rest}
                  </>
                ) : decorative ? (
                  <span className="cv-status-verb">
                    {verbSizes}
                    <span className="cv-status-verb__word">{label}</span>
                  </span>
                ) : (
                  label
                )
              }
              lit={
                <>
                  <span className={`cv-shimmer__lit-label${decorative ? " cv-status-verb" : ""}`} data-text={label}>
                    {decorative && verbSizes}
                  </span>
                  {elapsed && <span className="cv-shimmer__lit-time" data-text={elapsed} />}
                </>
              }
            />
          </output>
          {elapsed && <span className={own ? "cv-worked__own" : "cv-worked__time"}>{elapsed}</span>}
        </span>
      )}
      {own && !waiting && (
        <span className="cv-worked__count cv-worked__total">
          <span className="cv-worked__sep" aria-hidden="true">
            ·
          </span>
          <span className="cv-worked__time">{turnTime}</span>
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
