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
};

// One read when the unavailable card appears. A resume watches for at most one minute, and
// stops on disposal, changed chat/account, deletion, or the chat reopening (unmount).
export function useCloudChatRecovery({ cloud, session, active, recheck }: Props) {
  const t = useT();
  const [state, setState] = useState<CloudChatState>();
  const [resuming, setResuming] = useState(false);
  const [error, setError] = useState(false);
  const [readRevision, setReadRevision] = useState(0);
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
    let disposed = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let deadlineTimer: ReturnType<typeof setTimeout> | undefined;
    let cancelDeadline: (() => void) | undefined;
    const deadline = Date.now() + 60_000;
    if (!resuming) setState(undefined);
    const finishResume = (failed = false) => {
      // Late attach failures no longer own the card after recovery stops.
      resumeAttempt.current += 1;
      resumeInFlight.current = false;
      setResuming(false);
      if (failed) setError(true);
    };
    // A failed or superseded inventory read says nothing about the accepted wake.
    // Keep the paused card and the original deadline while the machine reconnects.
    const retry = () => {
      if (disposed || !resuming) return;
      if (Date.now() < deadline) {
        timer = setTimeout(() => void read(), 1_000);
      } else {
        finishResume(true);
      }
    };
    // Each request shares the resume's original deadline. Cleanup also settles a hung
    // request so its continuation can observe disposal without waiting on the native reply.
    const beforeDeadline = async <T>(
      work: Promise<T>,
    ): Promise<{ kind: "done"; value: T } | { kind: "deadline" } | { kind: "disposed" }> => {
      try {
        return await Promise.race([
          work.then((value) => ({ kind: "done" as const, value })),
          new Promise<{ kind: "deadline" | "disposed" }>((resolve) => {
            cancelDeadline = () => resolve({ kind: "disposed" });
            if (resuming) {
              deadlineTimer = setTimeout(() => resolve({ kind: "deadline" }), Math.max(0, deadline - Date.now()));
            }
          }),
        ]);
      } finally {
        if (deadlineTimer !== undefined) {
          clearTimeout(deadlineTimer);
          deadlineTimer = undefined;
        }
        cancelDeadline = undefined;
      }
    };
    const read = async () => {
      if (disposed || !identity || !active) return;
      try {
        const replyResult = await beforeDeadline(
          postNative(resuming ? "cloudMachine.list" : "cloudMachine.recoveryList"),
        );
        if (disposed || replyResult.kind === "disposed") return;
        if (replyResult.kind === "deadline") {
          finishResume(true);
          return;
        }
        const reply = replyResult.value;
        const next = cloudChatState(JSON.parse(identity) as CloudChatIdentity, reply);
        if (next !== undefined || !resuming) setState(next);
        if (resuming && next !== "deleted" && next !== undefined) {
          const result = await beforeDeadline(recheck());
          if (disposed) return;
          if (result.kind === "deadline") {
            finishResume(true);
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
      if (timer !== undefined) clearTimeout(timer);
      cancelDeadline?.();
      if (deadlineTimer !== undefined) clearTimeout(deadlineTimer);
    };
  }, [identity, session, active, resuming, recheck, readRevision]);

  const resume = () => {
    if (!cloud || resuming || resumeInFlight.current) return;
    resumeInFlight.current = true;
    setError(false);
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
    error: error ? t("unavailable.resumeFailed") : undefined,
  };
}
