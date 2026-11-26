// The local Mac connector. Status is safe before opt-in; only an opened connected list reads threads.
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { hasNativeHost, postNative } from "../native";
import type { Translate } from "../i18n";
import { useAutoRetry } from "../autoRetry";

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
  /// A read (its status, its threads) has failed for the house deadline while it is asked again on
  /// its own: the connector shows one quiet "Still trying to reach iMessage…" line, with no button.
  stillTrying: boolean;
};

export const IMESSAGE_INITIAL: IMessageData = {
  status: "not_connected",
  sends_enabled: false,
  threads: [],
  error: null,
};

/// What an iMessage error says. "missing" is an instruction (open Messages first); the list is read
/// again on its own meanwhile. "unavailable" shows only for a step the person chose (Connect, a
/// permission) that failed: its own button beside it is the way to take that step again.
export function imessageError(error: string, t: Translate): string {
  // retry-prompt-ok: "unavailable" follows a failed Connect or permission step, which only the person retakes.
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
  // A read that failed (its status or its thread list) is asked again on its own (autoRetry.ts): no
  // Try again button, since reading again has no cost and the only answer was ever yes (Leo,
  // 2026-11-22). A fresh object per failure arms the next ask. An action the person chose
  // (connect, a permission) that failed still says so at once, beside its own button.
  const [readFailed, setReadFailed] = useState<{ action: "status" | "threads" }>();
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
      if (live.current && id === revision.current) {
        // Messages has not made its database yet ("missing"): the list is read again on its own, so
        // opening Messages is all the person does; no Retry.
        setReadFailed(next.status === "connected" && next.error && opened.current ? { action: "threads" } : undefined);
        setData(next);
      }
    } catch {
      if (!live.current || id !== revision.current) return;
      // A read keeps what it showed (a thread list a moment old beats an empty one) and asks again.
      if (action === "status" || action === "threads") setReadFailed({ action });
      else setData((was) => ({ ...was, threads: [], error: "unavailable" }));
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
      setReadFailed(undefined);
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
  // A thread list is asked for again only while it is open; the status, always.
  const asking = enabled && supported && readFailed && (readFailed.action === "status" || expanded);
  const { stillTrying } = useAutoRetry(
    asking ? readFailed : undefined,
    () => {
      if (readFailed) void request(readFailed.action);
    },
    { busy },
  );
  // A transcript token changes Session Info's summary, not this connector. Keep its props stable
  // so a connected list (up to 500 threads) does no row work for those unrelated renders.
  return useMemo(
    () => (enabled && supported ? { data, busy, expanded, toggle, perform, stillTrying } : undefined),
    [enabled, supported, data, busy, expanded, toggle, perform, stillTrying],
  );
}
