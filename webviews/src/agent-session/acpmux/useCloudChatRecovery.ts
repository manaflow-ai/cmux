import { useEffect, useRef, useState } from "react";
import { cloudChatState, type CloudChatIdentity, type CloudChatState } from "./cloudChatRecovery";
import { postNative } from "./native";
import { NativeError } from "./nativeError";
import { useT } from "./i18n";

type Props = {
  cloud?: CloudChatIdentity;
  session?: string;
  active: boolean;
  recheck(): Promise<void>;
  /// Each read's deadline (RECOVERY_READ_MS); tests shorten it.
  readMs?: number;
};

/// How long a resume runs before the card says it is taking longer than usual and Resume machine is
/// clickable again (`slow`). The reads go on past it: a machine that is still starting keeps
/// reading until it answers (cmux#35206 removed the hard deadline on purpose).
export const RESUME_SLOW_MS = 60_000;

/// One read of the loop (the account's machine list, then the chat's recheck) shares this one
/// deadline. A read that has not answered by then is let go and the next read starts a second
/// later: the card never stops reading because one native call never came back (a starved Mac, a
/// bridge that lost the answer). It is not a failure and ends nothing; the whole resume still has no
/// deadline (cmux#35206), and a late answer of a read let go changes nothing.
export const RECOVERY_READ_MS = 20_000;

/// `work`'s answer, or `late` once `deadline` (a `performance.now()` time) passes. `work` is not
/// cancelled: a native call has no cancel, and its late answer or refusal is dropped here. `signal`
/// (the chat was left) ends the wait at once, so no deadline timer outlives the card.
export async function beforeDeadline<T>(
  work: Promise<T>,
  deadline: number,
  signal?: AbortSignal,
): Promise<{ kind: "done"; value: T } | { kind: "late" }> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  let onAbort: (() => void) | undefined;
  const late = new Promise<{ kind: "late" }>((resolve) => {
    timer = setTimeout(() => resolve({ kind: "late" }), Math.max(0, deadline - performance.now()));
    onAbort = () => resolve({ kind: "late" });
    if (signal?.aborted) onAbort();
    else signal?.addEventListener("abort", onAbort, { once: true });
  });
  // A refusal that comes after the deadline belongs to no one.
  work.catch(() => {});
  try {
    return await Promise.race([work.then((value) => ({ kind: "done" as const, value })), late]);
  } finally {
    clearTimeout(timer);
    if (onAbort) signal?.removeEventListener("abort", onAbort);
  }
}

// One read when the unavailable card appears. A resume reads the machine every second until the
// chat opens, the machine is deleted, a read fails for good, or the chat/account changes or
// unmounts; the resume has no deadline, each read has RECOVERY_READ_MS. Past RESUME_SLOW_MS it is
// `slow`, and Resume machine asks the machine to wake again while the reads continue.
export function useCloudChatRecovery({ cloud, session, active, recheck, readMs = RECOVERY_READ_MS }: Props) {
  const t = useT();
  const [state, setState] = useState<CloudChatState>();
  const [resuming, setResuming] = useState(false);
  const [error, setError] = useState(false);
  const [readRevision, setReadRevision] = useState(0);
  // Each click of Resume machine (the first, or one past the slow bound) starts its own slow clock.
  const [resumeRound, setResumeRound] = useState(0);
  const [slow, setSlow] = useState(false);
  const resumeAttempt = useRef(0);
  const resumeInFlight = useRef(false);
  const identity = cloud ? JSON.stringify(cloud) : undefined;
  useEffect(() => {
    resumeAttempt.current += 1;
    resumeInFlight.current = false;
    setResuming(false);
    setError(false);
    return () => {
      resumeAttempt.current += 1;
    };
  }, [identity, session]);
  useEffect(() => {
    if (!active) {
      resumeAttempt.current += 1;
      resumeInFlight.current = false;
      setResuming(false);
      setState(undefined);
    }
  }, [active]);
  useEffect(() => {
    if (!resuming) resumeInFlight.current = false;
  }, [resuming]);
  useEffect(() => {
    setSlow(false);
    if (!resuming) return;
    const timer = setTimeout(() => setSlow(true), RESUME_SLOW_MS);
    return () => clearTimeout(timer);
  }, [resuming, resumeRound]);
  useEffect(() => {
    let disposed = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const left = new AbortController();
    if (!resuming) setState(undefined);
    const finishResume = (failed = false) => {
      // Late attach failures no longer own the card after recovery stops.
      resumeAttempt.current += 1;
      resumeInFlight.current = false;
      setResuming(false);
      if (failed) setError(true);
    };
    // A failed or superseded inventory read says nothing about the accepted wake.
    // Keep the paused card while the machine reconnects.
    const retry = () => {
      if (disposed || !resuming) return;
      timer = setTimeout(() => void read(), 1_000);
    };
    // One deadline per read, shared by its list and its recheck. A read past it is let go and the
    // next one starts (`retry`): a slow machine is never a terminal resume failure, and a call that
    // never answers no longer stops the reads for good. The card reads again only while resuming.
    const read = async () => {
      if (disposed || !identity || !active) return;
      const deadline = performance.now() + readMs;
      try {
        const replyResult = await beforeDeadline(
          postNative(resuming ? "cloudMachine.list" : "cloudMachine.recoveryList"),
          deadline,
          left.signal,
        );
        if (disposed) return;
        if (replyResult.kind === "late") {
          retry();
          return;
        }
        const reply = replyResult.value;
        const next = cloudChatState(JSON.parse(identity) as CloudChatIdentity, reply);
        if (next !== undefined || !resuming) setState(next);
        if (resuming && next !== "deleted" && next !== undefined) {
          const rechecked = await beforeDeadline(recheck(), deadline, left.signal);
          if (disposed) return;
          if (rechecked.kind === "late") {
            retry();
            return;
          }
        }
        if (disposed) return;
        if (next === "deleted") {
          finishResume();
          return;
        }
        retry();
      } catch (cause) {
        if (disposed) return;
        if (resuming && cause instanceof NativeError && cause.retryable === false) {
          finishResume(true);
          return;
        }
        retry();
      }
    };
    void read();
    return () => {
      disposed = true;
      left.abort();
      if (timer !== undefined) clearTimeout(timer);
    };
  }, [identity, session, active, resuming, recheck, readRevision, readMs]);

  const resume = () => {
    // Past the slow bound a click wakes the machine again; the reads already running go on.
    const again = resuming && slow;
    if (!cloud || (resuming && !again) || (resumeInFlight.current && !again)) return;
    resumeInFlight.current = true;
    setError(false);
    setResumeRound((round) => round + 1);
    // Send the native call synchronously from the click: it consumes this gesture. The existing
    // attach path resumes this machine for either Cloud backend without opening another workspace.
    const attempt = ++resumeAttempt.current;
    const action = postNative("cloudMachine.attach", { id: cloud.id });
    setResuming(true);
    void action.catch(() => {
      if (resumeAttempt.current === attempt) {
        resumeAttempt.current += 1;
        resumeInFlight.current = false;
        setResuming(false);
        setError(true);
      }
    });
  };
  return {
    state: active ? state : undefined,
    resume,
    refresh: () => setReadRevision((value) => value + 1),
    resuming,
    /// The resume has run past RESUME_SLOW_MS: the card says so and Resume machine works again.
    slow: resuming && slow,
    error: error ? t("unavailable.resumeFailed") : undefined,
  };
}
