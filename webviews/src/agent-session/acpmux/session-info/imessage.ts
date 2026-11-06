// The local Mac connector. Status is safe before opt-in; only an opened connected list reads threads.
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { hasNativeHost, postNative } from "../native";
import type { Translate } from "../i18n";

export type IMessageStatus = "not_connected" | "needs_full_disk_access" | "needs_automation" | "connected";
export type IMessageThread = {
  chat_id: number;
  title: string;
  is_group: boolean;
  participants: string[];
  last_activity?: number | null;
};
export type IMessageData = {
  status: IMessageStatus;
  sends_enabled: boolean;
  threads: IMessageThread[];
  error: string | null;
};
export type IMessageAction =
  | "connect"
  | "disconnect"
  | "full_disk_access"
  | "automation"
  | "skip_automation"
  | "threads";
export type IMessageView = {
  data: IMessageData;
  busy: boolean;
  expanded: boolean;
  toggle: () => void;
  perform: (action: IMessageAction) => Promise<void>;
};

export const IMESSAGE_INITIAL: IMessageData = {
  status: "not_connected",
  sends_enabled: false,
  threads: [],
  error: null,
};

export function imessageError(error: string, t: Translate): string {
  return t(error === "missing" ? "imessage.missing" : "imessage.unavailable");
}

export function useIMessage(enabled = true): IMessageView | undefined {
  const supported = /Mac/.test(globalThis.navigator?.platform ?? "") && hasNativeHost();
  const [data, setData] = useState<IMessageData>(IMESSAGE_INITIAL);
  const [busy, setBusy] = useState(false);
  const [expanded, setExpanded] = useState(false);
  const opened = useRef(false);
  const revision = useRef(0);
  const live = useRef(false);
  const stop = useCallback(() => {
    live.current = false;
    revision.current++;
  }, []);
  const request = useCallback(async (action: IMessageAction | "status") => {
    const id = ++revision.current;
    try {
      let next = await postNative<IMessageData>(`imessage.${action}`);
      if (!live.current || id !== revision.current) return;
      if (next.status === "connected" && opened.current && action !== "threads")
        next = await postNative<IMessageData>("imessage.threads");
      if (live.current && id === revision.current) setData(next);
    } catch {
      if (live.current && id === revision.current) setData((was) => ({ ...was, threads: [], error: "unavailable" }));
    }
  }, []);
  useEffect(() => {
    if (!enabled || !supported) return;
    live.current = true;
    const refresh = () => {
      void request("status");
    };
    refresh();
    window.addEventListener("cmux-imessage-changed", refresh);
    return () => {
      stop();
      window.removeEventListener("cmux-imessage-changed", refresh);
    };
  }, [enabled, supported, request, stop]);
  const perform = useCallback(
    async (action: IMessageAction) => {
      opened.current = action !== "disconnect";
      setExpanded(opened.current);
      setBusy(true);
      try {
        await request(action);
      } finally {
        setBusy(false);
      }
    },
    [request],
  );
  const toggle = useCallback(() => {
    if (busy) return;
    opened.current = !opened.current;
    setExpanded(opened.current);
    if (opened.current && data.status === "connected") void perform("threads");
  }, [busy, data.status, perform]);
  // A transcript token changes Session Info's summary, not this connector. Keep its props stable
  // so a connected list (up to 500 threads) does no row work for those unrelated renders.
  return useMemo(
    () => (enabled && supported ? { data, busy, expanded, toggle, perform } : undefined),
    [enabled, supported, data, busy, expanded, toggle, perform],
  );
}
