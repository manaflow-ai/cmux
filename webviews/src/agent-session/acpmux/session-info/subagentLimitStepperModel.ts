import { useEffect, useRef, useState } from "react";
import type { SubsessionLimits } from "../model";
import { clampRunning, MAX_RUNNING } from "../subsessionLimits";
import { nextSubagentLimitAsk, type SubagentLimitAsk } from "./native/limit";

/// How long a refused change says so.
const REFUSAL_MS = 4_000;

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
