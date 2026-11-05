// Shared native render-frame transport and the page-lifetime Run permission cache.
import { useEffect, useRef, useState } from "react";
import { renderFrameCSS } from "./renderBase";
import { RENDER_FRAME_MIN_HEIGHT } from "./renderCall";

const EXPANDED_MAX_HEIGHT = 4000;

/// The HTML the reader has run while this pane lives: a card scrolled away and back keeps
/// running, and a reloaded pane (after a hang or a crash) starts with every card waiting again.
export const ranRenders = new Set<string>();

/// Feeds `html` to a render frame once it asks for it, and follows the height the frame reports.
export function useRenderFrame(html: string) {
  const frame = useRef<HTMLIFrameElement>(null);
  const [height, setHeight] = useState(RENDER_FRAME_MIN_HEIGHT);
  useEffect(() => {
    const onMessage = (event: MessageEvent) => {
      const target = frame.current?.contentWindow;
      if (!target || event.source !== target) return;
      const data: unknown = event.data;
      if (!data || typeof data !== "object") return;
      const message = data as { type?: unknown; height?: unknown };
      if (message.type === "cmux-render-ready")
        target.postMessage({ type: "cmux-render", html, css: renderFrameCSS() }, "*");
      else if (
        message.type === "cmux-render-size" &&
        typeof message.height === "number" &&
        Number.isFinite(message.height)
      )
        setHeight(Math.min(EXPANDED_MAX_HEIGHT, Math.max(RENDER_FRAME_MIN_HEIGHT, Math.ceil(message.height))));
    };
    addEventListener("message", onMessage);
    return () => removeEventListener("message", onMessage);
  }, [html]);
  return { frame, height };
}
