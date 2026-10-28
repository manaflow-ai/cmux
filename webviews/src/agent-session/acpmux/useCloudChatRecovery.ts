import { useEffect, useRef, useState } from "react";
import { cloudChatState, type CloudChatIdentity, type CloudChatState } from "./cloudChatRecovery";
import { postNative } from "./native";
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
  const actionGeneration = useRef(0);
  const identity = cloud ? JSON.stringify(cloud) : undefined;
  useEffect(() => {
    actionGeneration.current += 1;
    setResuming(false);
    setError(false);
    return () => {
      actionGeneration.current += 1;
    };
  }, [identity, session]);
  useEffect(() => {
    if (!active) {
      setResuming(false);
      setState(undefined);
    }
  }, [active]);
  useEffect(() => {
    let disposed = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const deadline = Date.now() + 60_000;
    if (!resuming) setState(undefined);
    const read = async () => {
      if (!identity || !active) return;
      try {
        const reply = await postNative(resuming ? "cloudMachine.list" : "cloudMachine.recoveryList");
        if (disposed) return;
        const next = cloudChatState(JSON.parse(identity) as CloudChatIdentity, reply);
        setState(next);
        if (resuming && next !== "deleted" && next !== undefined) await recheck();
        if (disposed) return;
        if (resuming && next !== "deleted" && next !== undefined && Date.now() < deadline) {
          timer = setTimeout(() => void read(), 1_000);
        } else if (resuming) {
          setResuming(false);
          setError(next !== "deleted");
        }
      } catch {
        if (!disposed && resuming) {
          setResuming(false);
          setError(true);
        }
      }
    };
    void read();
    return () => {
      disposed = true;
      if (timer !== undefined) clearTimeout(timer);
    };
  }, [identity, session, active, resuming, recheck]);

  const resume = () => {
    if (!cloud || resuming) return;
    setError(false);
    // Send the native call synchronously from the click: it consumes this gesture. The existing
    // attach path resumes this machine for either Cloud backend without opening another workspace.
    const generation = actionGeneration.current;
    const action = postNative("cloudMachine.attach", { id: cloud.id });
    setResuming(true);
    void action.catch(() => {
      if (actionGeneration.current === generation) {
        setResuming(false);
        setError(true);
      }
    });
  };
  return {
    state: active ? state : undefined,
    resume,
    resuming,
    error: error ? t("unavailable.resumeFailed") : undefined,
  };
}
