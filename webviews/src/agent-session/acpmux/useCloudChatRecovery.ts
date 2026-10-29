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
  const actionGeneration = useRef(0);
  const resumeInFlight = useRef(false);
  const identity = cloud ? JSON.stringify(cloud) : undefined;
  useEffect(() => {
    actionGeneration.current += 1;
    resumeInFlight.current = false;
    setResuming(false);
    setError(false);
    return () => {
      actionGeneration.current += 1;
    };
  }, [identity, session]);
  useEffect(() => {
    if (!active) {
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
    const deadline = Date.now() + 60_000;
    if (!resuming) setState(undefined);
    // A failed or superseded inventory read says nothing about the accepted wake.
    // Keep the paused card and the original deadline while the machine reconnects.
    const retry = () => {
      if (disposed || !resuming) return;
      if (Date.now() < deadline) {
        timer = setTimeout(() => void read(), 1_000);
      } else {
        setResuming(false);
        setError(true);
      }
    };
    const read = async () => {
      if (!identity || !active) return;
      try {
        const reply = await postNative(resuming ? "cloudMachine.list" : "cloudMachine.recoveryList");
        if (disposed) return;
        const next = cloudChatState(JSON.parse(identity) as CloudChatIdentity, reply);
        if (next !== undefined || !resuming) setState(next);
        if (resuming && next !== "deleted" && next !== undefined) await recheck();
        if (disposed) return;
        if (next === "deleted") {
          setResuming(false);
          return;
        }
        retry();
      } catch (cause) {
        if (resuming && cause instanceof NativeError && cause.retryable === false) {
          setResuming(false);
          setError(true);
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

  const resume = () => {
    if (!cloud || resuming || resumeInFlight.current) return;
    resumeInFlight.current = true;
    setError(false);
    // Send the native call synchronously from the click: it consumes this gesture. The existing
    // attach path resumes this machine for either Cloud backend without opening another workspace.
    const generation = actionGeneration.current;
    const action = postNative("cloudMachine.attach", { id: cloud.id });
    setResuming(true);
    void action.catch(() => {
      if (actionGeneration.current === generation) {
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
