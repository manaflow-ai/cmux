import { useCallback, useContext, useEffect, useRef, useState } from "react";
import { copyTextResult } from "./clipboard";
import { RenderBridgeContext } from "./RenderBridgeContext";
import { renderState, saveRenderState } from "./renderState";

type Reply = (ok: boolean, value?: unknown) => void;
type Pending = { method: "sendPrompt" | "openLink" | "prefill" | "copy"; text: string; reply: Reply };

export function useRenderRequests(key: string) {
  const bridge = useContext(RenderBridgeContext);
  const [pending, setPending] = useState<Pending>();
  const held = useRef<Pending | undefined>(undefined);
  const [copied, setCopied] = useState(false);
  const rate = useRef<number[]>([]);
  const cancel = useCallback(() => {
    held.current?.reply(false, "cancelled");
    held.current = undefined;
    setPending(undefined);
  }, []);
  useEffect(() => cancel, [key, cancel]);
  useEffect(() => {
    if (!copied) return;
    const timer = setTimeout(() => setCopied(false), 1500);
    return () => clearTimeout(timer);
  }, [copied]);
  const request = useCallback(
    (data: Record<string, unknown>, target: Window) => {
      if (typeof data.id !== "string" || data.id.length > 100) return;
      const id = data.id;
      const reply: Reply = (ok, value) =>
        target.postMessage(
          {
            type: "cmux-render-reply",
            id,
            ok,
            ...(ok ? { value } : { error: value }),
          },
          "*",
        );
      const now = Date.now();
      rate.current = rate.current.filter((at) => now - at < 1000);
      if (rate.current.length >= 5) return reply(false, "rate limit");
      rate.current.push(now);
      const params = data.params;
      if (!params || typeof params !== "object" || Array.isArray(params)) return reply(false, "invalid params");
      const args = params as Record<string, unknown>;
      if (data.method === "state.get") return reply(true, renderState(key));
      if (data.method === "state.set") {
        try {
          const json = JSON.stringify(args.value);
          if (!json || new TextEncoder().encode(json).length > 65536) return reply(false, "invalid state");
          saveRenderState(key, JSON.parse(json));
          return reply(true, null);
        } catch {
          return reply(false, "invalid state");
        }
      }
      const method = data.method;
      if (method !== "prefill" && method !== "sendPrompt" && method !== "copy" && method !== "openLink")
        return reply(false, "unknown method");
      const text = method === "openLink" ? args.url : args.text;
      if (typeof text !== "string" || text.length > 4000 || !text.trim()) return reply(false, "invalid text");
      if (method === "openLink") {
        try {
          if (new URL(text).protocol !== "https:") return reply(false, "https required");
        } catch {
          return reply(false, "invalid url");
        }
      }
      if (method !== "copy" && !bridge) return reply(false, "unavailable");
      if (held.current) return reply(false, "confirmation pending");
      held.current = { method, text, reply };
      setPending(held.current);
    },
    [key, bridge],
  );
  const confirm = (edit: boolean) => {
    const ask = pending;
    // A cancelled request cannot borrow a click from its previous strip.
    if (!ask || held.current !== ask || (ask.method !== "copy" && !bridge)) return;
    held.current = undefined;
    setPending(undefined);
    if (ask.method === "copy") {
      void copyTextResult(ask.text).then((ok) => {
        setCopied(ok);
        ask.reply(ok, ok ? null : "copy failed");
      });
      return;
    }
    if (edit || ask.method === "prefill") {
      bridge!.prefill(ask.text);
      ask.reply(true, null);
      return;
    }
    try {
      const result = ask.method === "sendPrompt" ? bridge!.send(ask.text) : bridge!.openLink(ask.text);
      void Promise.resolve(result).then(
        (value) => {
          const ok = ask.method === "openLink" ? value === true : value !== false;
          ask.reply(ok, ok ? null : "unavailable");
        },
        () => ask.reply(false, "unavailable"),
      );
    } catch {
      ask.reply(false, "unavailable");
    }
  };
  return { request, pending, copied, confirm, cancel };
}
