// The Subagents card's running limit: how many of the chats this chat's agent started (its
// sub-sessions) run a turn at once, "Running 8 / 16 max", with − and + beside it and "3 queued"
// while some wait for a free slot. Leo, 2026-10-21: "increase or decrease subagent amounts ad
// hoc". − and + set the chat's own limit one lower or higher (1 to 1000) through
// `_acpmux/subsession/limits`; the number moves at once and acpmux's answer, or its `limits`
// record, then says what holds. Reset drops the chat's own limit for the one it inherits. Shown
// whenever acpmux names the limit, before any chat starts too, so a cap can be set up front; an
// acpmux without it draws nothing. A refused change says so for a few seconds. Without `onSet` (a
// chat on another machine, or a connection acpmux does not take it from) the limit only reads.
import { useEffect, useRef, useState } from "react";
import { useT } from "../i18n";
import type { SubsessionLimits } from "../model";
import type { StartedSession } from "../started/startedSessions";
import { clampRunning, MAX_RUNNING, slotCounts } from "../subsessionLimits";
import "./SubagentLimitStepper.css";

/// How long a refused change says so.
const REFUSAL_MS = 4_000;

/// The glyphs of action.add's 24-unit grid (icons/cmuxIcons.json), drawn as a pair.
const MINUS = "M5 12L19 12";
const PLUS = "M12 5L12 19M5 12L19 12";

function Glyph({ d }: { d: string }) {
  return (
    <svg viewBox="0 0 24 24" width="11" height="11" aria-hidden="true" focusable="false">
      <path d={d} fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
    </svg>
  );
}

export function SubagentLimitStepper({
  chatId,
  limits,
  sessions = [],
  onSet,
}: {
  /// The chat whose limit this is: a value asked for another chat never shows here.
  chatId?: string;
  limits?: SubsessionLimits;
  /// The chats its agent started, for the live counts.
  sessions?: readonly StartedSession[];
  /// `_acpmux/subsession/limits` for this chat: a number sets its own limit, `null` drops it. A step
  /// names the limit it stepped `from`, so a limit that moved meanwhile (an ancestor's, the
  /// workspace's or the settings', which reach this chat as no record) is stepped from instead.
  onSet?: (maxRunning: number | null, from?: number) => Promise<unknown>;
}) {
  const t = useT();
  // The value a click asked for, until acpmux's answer: kept with the chat and the limits it may
  // still stand over (the one the first click saw, then each value asked since), so another chat,
  // or a limit from acpmux that is none of those (another client, a refusal), replaces it. An
  // earlier click's reply landing (16 → 17 while 18 is still asked) keeps the newer ask.
  const [asked, setAsked] = useState<{ chat?: string; over: readonly number[]; value: number }>();
  const [refused, setRefused] = useState<{ chat?: string; at: number }>();
  // Clicks acpmux has not answered yet: the asked value stands until the last one is answered.
  const inFlight = useRef(0);
  useEffect(() => {
    if (!refused) return;
    const timer = setTimeout(() => setRefused(undefined), REFUSAL_MS);
    return () => clearTimeout(timer);
  }, [refused]);
  if (!limits) return null;
  const standing = asked !== undefined && asked.chat === chatId && asked.over.includes(limits.maxRunning);
  const pending = standing && asked ? asked.value : undefined;
  const max = pending ?? limits.maxRunning;
  const failed = refused !== undefined && refused.chat === chatId;
  const { running, queued } = slotCounts(limits, sessions);
  const set = (value: number | null, from?: number) => {
    if (!onSet) return;
    const chat = chatId;
    setRefused(undefined);
    if (value !== null) {
      const over = standing && asked ? [...asked.over, asked.value] : [limits.maxRunning];
      setAsked({ chat, over, value });
    }
    inFlight.current += 1;
    const answered = () => {
      inFlight.current -= 1;
      if (inFlight.current === 0) setAsked(undefined);
    };
    // A handler that returns no promise, or throws, still settles the line (never an unhandled error).
    Promise.resolve()
      .then(() => onSet(value, from))
      .then(answered, () => {
        answered();
        setRefused({ chat, at: Date.now() });
      });
  };
  const step = (by: number) => set(clampRunning(max + by), max);
  const own = limits.maxRunningSource === "session";
  return (
    <div className="acpmux-subagent-limit">
      <span className="acpmux-subagent-limit__text">
        {t("chatInspector.subagents.limit.running", { running, max })}
        {queued > 0 && (
          <span className="acpmux-subagent-limit__queued">
            {" · "}
            {t("chatInspector.subagents.limit.queued", { n: queued })}
          </span>
        )}
      </span>
      <output className="acpmux-subagent-limit__refused">
        {failed ? t("chatInspector.subagents.limit.refused") : ""}
      </output>
      {onSet && (
        <span className="acpmux-subagent-limit__controls">
          {own && (
            <button
              type="button"
              className="acpmux-subagent-limit__reset"
              aria-label={t("chatInspector.subagents.limit.resetLabel")}
              title={t("chatInspector.subagents.limit.resetLabel")}
              onClick={() => set(null)}
            >
              {t("chatInspector.subagents.limit.reset")}
            </button>
          )}
          <button
            type="button"
            className="acpmux-chat-inspector-icon-button"
            disabled={max <= MAX_RUNNING.min}
            aria-label={t("chatInspector.subagents.limit.lower", { n: clampRunning(max - 1) })}
            title={t("chatInspector.subagents.limit.lower", { n: clampRunning(max - 1) })}
            onClick={() => step(-1)}
          >
            <Glyph d={MINUS} />
          </button>
          <button
            type="button"
            className="acpmux-chat-inspector-icon-button"
            disabled={max >= MAX_RUNNING.max}
            aria-label={t("chatInspector.subagents.limit.raise", { n: clampRunning(max + 1) })}
            title={t("chatInspector.subagents.limit.raise", { n: clampRunning(max + 1) })}
            onClick={() => step(1)}
          >
            <Glyph d={PLUS} />
          </button>
        </span>
      )}
    </div>
  );
}
