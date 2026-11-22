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
  /// The resume in flight is the passive one opening the chat ran (`wake`), not a person's attach.
  const [waking, setWaking] = useState(false);
  /// The platform refused that passive wake (a plan or machine cap stop, a list not loaded): the
  /// paused card shows Resume machine, the person's own attach, which says why.
  const [wakeRefused, setWakeRefused] = useState(false);
  const resumeAttempt = useRef(0);
  const resumeInFlight = useRef(false);
  const wakingNow = useRef(false);
  const identity = cloud ? JSON.stringify(cloud) : undefined;
  useEffect(() => {
    resumeAttempt.current += 1;
    resumeInFlight.current = false;
    wakingNow.current = false;
    setResuming(false);
    setWaking(false);
    setWakeRefused(false);
    setError(false);
    return () => {
      resumeAttempt.current += 1;
    };
  }, [identity, session]);
  useEffect(() => {
    if (!active) {
      resumeAttempt.current += 1;
      resumeInFlight.current = false;
      wakingNow.current = false;
      setResuming(false);
      setWaking(false);
      setState(undefined);
    }
  }, [active]);
  useEffect(() => {
    if (resuming) return;
    resumeInFlight.current = false;
    wakingNow.current = false;
    setWaking(false);
  }, [resuming]);
  useEffect(() => {
    let disposed = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
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
    // A live native bridge owns the request's lifetime. Cleanup only settles a request when this
    // effect is disposed; a busy machine never turns a slow list into a terminal resume failure.
    const beforeDeadline = async <T>(work: Promise<T>): Promise<{ kind: "done"; value: T }> => ({
      kind: "done",
      value: await work,
    });
    const read = async () => {
      if (disposed || !identity || !active) return;
      try {
        const replyResult = await beforeDeadline(
          postNative(resuming ? "cloudMachine.list" : "cloudMachine.recoveryList"),
        );
        if (disposed) return;
        const reply = replyResult.value;
        const next = cloudChatState(JSON.parse(identity) as CloudChatIdentity, reply);
        if (next !== undefined || !resuming) setState(next);
        if (resuming && next !== "deleted" && next !== undefined) {
          await beforeDeadline(recheck());
          if (disposed) return;
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
    };
  }, [identity, session, active, resuming, recheck, readRevision]);

  // A person's resume (the card's button, a keystroke, a Send) during the passive wake still posts
  // the attach with its gesture: the attach owns the resume from then on, and its failure says so.
  const resume = () => {
    if (!cloud || ((resuming || resumeInFlight.current) && !wakingNow.current)) return;
    resumeInFlight.current = true;
    wakingNow.current = false;
    setWaking(false);
    setWakeRefused(false);
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
  // Opening the chat (cloudWake.ts `cloudOpenWakes`): the same resume and reconnect, through the
  // passive `cloudMachine.prewarm`, which takes no gesture. A refusal ends it quietly: no error
  // line, the paused card and its Resume machine are the fallback.
  const wake = () => {
    if (!cloud || resuming || resumeInFlight.current) return;
    resumeInFlight.current = true;
    wakingNow.current = true;
    setWakeRefused(false);
    setError(false);
    const attempt = ++resumeAttempt.current;
    const action = postNative("cloudMachine.prewarm", { id: cloud.id });
    setResuming(true);
    setWaking(true);
    void action.catch(() => {
      if (resumeAttempt.current === attempt) {
        resumeAttempt.current += 1;
        resumeInFlight.current = false;
        wakingNow.current = false;
        setResuming(false);
        setWaking(false);
        setWakeRefused(true);
      }
    });
  };
  return {
    state: active ? state : undefined,
    resume,
    wake,
    waking,
    wakeRefused,
    refresh: () => setReadRevision((value) => value + 1),
    resuming,
    error: error ? t("unavailable.resumeFailed") : undefined,
  };
}
