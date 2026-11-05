// The Subagents card's running limit: how many of the chats this chat's agent started (its
// sub-sessions) run a turn at once, "Started chats: 8 of 16 at once" (never its own Agent subagents, which the line once seemed to count: Leo, 2026-11-02, "but what's going on with these?"), with − and + beside it and "3 queued"
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
import { nextSubagentLimitAsk, type SubagentLimitAsk } from "./native/limit";

/// How long a refused change says so.
const REFUSAL_MS = 4_000;

/// The glyphs of action.add's 24-unit grid (icons/cmuxIcons.json), drawn as a pair.
const MINUS = "M5 12L19 12";
const PLUS = "M12 5L12 19M5 12L19 12";

function Glyph({ d }: { d: string }) {
  return (
    <svg viewBox="0 0 24 24" width="12" height="12" aria-hidden="true" focusable="false">
      <path d={d} fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
    </svg>
  );
}

export type SubagentLimitController = {
  /// The effective value to display, including the latest optimistic request.
  max: number;
  /// The requested value while one or more calls are in flight for this chat.
  pendingMax?: number;
  /// `pending` while a request is in flight, `failed` for the short refusal message.
  state?: "pending" | "failed";
  set(value: number | null, from?: number): void;
  step(by: number): void;
  reset(): void;
};

/**
 * Keeps the running-limit interaction optimistic while preserving out-of-order replies.
 *
 * Each request remembers the limit values it was based on. A reply only removes the optimistic
 * value after the last request settles; an older reply therefore cannot overwrite a newer click.
 * A rejection is surfaced for the same four seconds as the visible stepper.
 */
export function useSubagentLimitController({
  chatId,
  limits,
  onSet,
}: {
  chatId?: string;
  limits?: SubsessionLimits;
  onSet?: (maxRunning: number | null, from?: number) => Promise<unknown>;
}): SubagentLimitController {
  const [asked, setAsked] = useState<SubagentLimitAsk>();
  const askedRef = useRef<SubagentLimitAsk | undefined>(undefined);
  const [refused, setRefused] = useState<{ chat?: string; at: number }>();
  const [inFlightCount, setInFlightCount] = useState(0);
  const inFlight = useRef(0);
  useEffect(() => {
    if (!refused) return;
    const timer = setTimeout(() => setRefused(undefined), REFUSAL_MS);
    return () => clearTimeout(timer);
  }, [refused]);

  const current = limits?.maxRunning ?? MAX_RUNNING.min;
  const standing = asked !== undefined && asked.chat === chatId && asked.over.includes(current);
  const pendingMax = standing ? asked?.value : undefined;
  const max = pendingMax ?? current;
  const latestMax = useRef(max);
  latestMax.current = max;
  const set = (value: number | null, from?: number) => {
    if (!onSet || !limits) return;
    const chat = chatId;
    setRefused(undefined);
    if (value !== null) {
      const next = nextSubagentLimitAsk(askedRef.current, chat, current, value);
      askedRef.current = next;
      setAsked(next);
    }
    inFlight.current += 1;
    setInFlightCount(inFlight.current);
    const answered = () => {
      inFlight.current = Math.max(0, inFlight.current - 1);
      setInFlightCount(inFlight.current);
      if (inFlight.current === 0) {
        askedRef.current = undefined;
        setAsked(undefined);
      }
    };
    Promise.resolve()
      .then(() => onSet(value, from))
      .then(answered, () => {
        answered();
        setRefused({ chat, at: Date.now() });
      });
  };
  return {
    max,
    ...(pendingMax !== undefined ? { pendingMax } : {}),
    ...(refused !== undefined && refused.chat === chatId
      ? { state: "failed" as const }
      : inFlightCount > 0
        ? { state: "pending" as const }
        : {}),
    set,
    step: (by) => {
      const from = latestMax.current;
      const value = clampRunning(from + by);
      latestMax.current = value;
      set(value, from);
    },
    reset: () => set(null),
  };
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
  const controller = useSubagentLimitController({ chatId, limits, onSet });
  if (!limits) return null;
  const { max, state, step } = controller;
  const { running, queued } = slotCounts(limits, sessions);
  const own = limits.maxRunningSource === "session";
  return (
    <div className="acpmux-subagent-limit">
      <span className="acpmux-subagent-limit__text">
        {t("sessionInfo.subagents.limit.startedChats", { running, max })}
        {queued > 0 && (
          <span className="acpmux-subagent-limit__queued">
            {" · "}
            {t("sessionInfo.subagents.limit.queued", { n: queued })}
          </span>
        )}
      </span>
      <output className="acpmux-subagent-limit__refused">
        {state === "failed" ? t("sessionInfo.subagents.limit.refused") : ""}
      </output>
      {onSet && (
        <span className="acpmux-subagent-limit__controls">
          {own && (
            <button
              type="button"
              className="acpmux-subagent-limit__reset"
              aria-label={t("sessionInfo.subagents.limit.resetLabel")}
              title={t("sessionInfo.subagents.limit.resetLabel")}
              onClick={() => controller.reset()}
            >
              {t("sessionInfo.subagents.limit.reset")}
            </button>
          )}
          <button
            type="button"
            className="acpmux-session-info-icon-button"
            disabled={max <= MAX_RUNNING.min}
            aria-label={t("sessionInfo.subagents.limit.lower", { n: clampRunning(max - 1) })}
            title={t("sessionInfo.subagents.limit.lower", { n: clampRunning(max - 1) })}
            onClick={() => step(-1)}
          >
            <Glyph d={MINUS} />
          </button>
          <button
            type="button"
            className="acpmux-session-info-icon-button"
            disabled={max >= MAX_RUNNING.max}
            aria-label={t("sessionInfo.subagents.limit.raise", { n: clampRunning(max + 1) })}
            title={t("sessionInfo.subagents.limit.raise", { n: clampRunning(max + 1) })}
            onClick={() => step(1)}
          >
            <Glyph d={PLUS} />
          </button>
        </span>
      )}
    </div>
  );
}
