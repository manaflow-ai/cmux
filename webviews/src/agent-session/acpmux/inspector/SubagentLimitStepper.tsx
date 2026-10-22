// The Subagents card's running limit: how many of the chats this chat's agent started (its
// sub-sessions) run a turn at once, "Running 8 / 16 max", with − and + beside it and "3 queued"
// while some wait for a free slot. Leo, 2026-10-21: "increase or decrease subagent amounts ad
// hoc". − and + set the chat's own limit one lower or higher (1 to 1000) through
// `_acpmux/subsession/limits`; the number moves at once and acpmux's answer, or its `limits`
// record, then says what holds. Reset drops the chat's own limit for the one it inherits. Shown
// whenever acpmux names the limit, before any chat starts too, so a cap can be set up front; an
// acpmux without it draws nothing.
import { useRef, useState } from "react";
import { useT } from "../i18n";
import type { SubsessionLimits } from "../model";
import type { StartedSession } from "../started/startedSessions";
import { clampRunning, MAX_RUNNING, slotCounts } from "../subsessionLimits";
import "./SubagentLimitStepper.css";

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
  limits,
  sessions = [],
  onSet,
}: {
  limits?: SubsessionLimits;
  /// The chats its agent started, for the live counts.
  sessions?: readonly StartedSession[];
  /// `_acpmux/subsession/limits` for this chat: a number sets its own limit, `null` drops it.
  onSet?: (maxRunning: number | null) => Promise<unknown>;
}) {
  const t = useT();
  // The value a click asked for, until acpmux's answer: kept with the limit it was asked over, so a
  // new limit from acpmux (the reply, a record, another client) replaces it.
  const [asked, setAsked] = useState<{ over: number; value: number }>();
  // Clicks acpmux has not answered yet: the asked value stands until the last one is answered.
  const inFlight = useRef(0);
  if (!limits) return null;
  const max = asked && asked.over === limits.maxRunning ? asked.value : limits.maxRunning;
  const { running, queued } = slotCounts(limits, sessions);
  const set = (value: number | null) => {
    if (!onSet) return;
    const over = limits.maxRunning;
    if (value !== null) setAsked({ over, value });
    inFlight.current += 1;
    const answered = () => {
      inFlight.current -= 1;
      if (inFlight.current === 0) setAsked(undefined);
    };
    onSet(value).then(answered, answered);
  };
  const step = (by: number) => set(clampRunning(max + by));
  const own = limits.maxRunningSource === "session";
  return (
    <div className="acpmux-subagent-limit" role="group" aria-label={t("chatInspector.subagents.limit.group")}>
      <span className="acpmux-subagent-limit__text">
        {t("chatInspector.subagents.limit.running", { running, max })}
        {queued > 0 && (
          <span className="acpmux-subagent-limit__queued">
            {" · "}
            {t("chatInspector.subagents.limit.queued", { n: queued })}
          </span>
        )}
      </span>
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
