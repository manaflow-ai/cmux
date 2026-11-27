// The native transcript (RFD 0121's decided call, "a native Rust transcript, first read-only behind a
// flag"): behind Settings > Advanced > Experiments `nativeTranscript`, default off. When on, a canvas
// covers the transcript's scroller while it follows the bottom, and a Worker paints it: the Worker reads
// the chat from its own daemon socket, Rust (transcript_view.wasm) shapes and lays out the rows, and the
// Worker draws them on its own frames, so the visible chat's frames stop waiting on this page's main
// thread. Leo: "Why should non visible thing even affect the renderer thread anyways?"
//
// Read-only and additive: the React transcript stays mounted underneath and takes the input, and is
// what shows once the person scrolls up. Only a real socket has a link a Worker can dial
// (direct.ts `nativeLink`); over the app's bridge this draws nothing yet.
import { useEffect, useRef, useState } from "react";
import { useExperimentSwitch } from "../../../experiments/switches";
import type { NativeTranscriptCommand } from "./worker";

type Link = { endpoint: string; protocols?: string[] };

/** The scroller follows the bottom when it is within this many px of it. */
const BOTTOM_SLACK_PX = 4;

export function NativeTranscript({ link, sessionId }: { link: () => Link | undefined; sessionId: string | undefined }) {
  const on = useExperimentSwitch("nativeTranscript");
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const [atBottom, setAtBottom] = useState(true);

  useEffect(() => {
    const canvas = canvasRef.current;
    const target = on && sessionId ? link() : undefined;
    if (!canvas || !target || !sessionId || typeof OffscreenCanvas !== "function") return;
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
    if (!scroller) return;
    let worker: Worker;
    try {
      worker = new Worker(new URL("./worker.ts", import.meta.url), { type: "module" });
    } catch {
      return;
    }
    const style = getComputedStyle(scroller);
    const offscreen = canvas.transferControlToOffscreen();
    const start: NativeTranscriptCommand = {
      type: "start",
      canvas: offscreen,
      endpoint: target.endpoint,
      protocols: target.protocols,
      sessionId,
      font: `${style.fontSize || "13px"} ${style.fontFamily || "sans-serif"}`,
      lineHeight: Number.parseFloat(style.lineHeight) || 18,
      // The canvas needs resolved colours, so read the theme's tokens as the scroller computes them.
      colors: {
        text: style.getPropertyValue("--cmux-text").trim() || style.color,
        muted: style.getPropertyValue("--cmux-text-secondary").trim() || style.color,
        background:
          style.getPropertyValue("--cmux-surface-background").trim() || getComputedStyle(document.body).backgroundColor,
      },
      tally: new URLSearchParams(location.hash.slice(1)).get("nativeTally") === "1",
    };
    worker.postMessage(start, [offscreen]);
    const place = () => {
      const box = scroller.getBoundingClientRect();
      Object.assign(canvas.style, {
        left: `${box.left}px`,
        top: `${box.top}px`,
        width: `${box.width}px`,
        height: `${box.height}px`,
      });
      const view: NativeTranscriptCommand = {
        type: "view",
        width: box.width,
        height: box.height,
        dpr: devicePixelRatio || 1,
      };
      worker.postMessage(view);
    };
    const follow = () =>
      setAtBottom(scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight <= BOTTOM_SLACK_PX);
    place();
    follow();
    const resize = new ResizeObserver(place);
    resize.observe(scroller);
    scroller.addEventListener("scroll", follow, { passive: true });
    return () => {
      resize.disconnect();
      scroller.removeEventListener("scroll", follow);
      worker.terminate();
    };
  }, [on, sessionId, link]);

  if (!on || !sessionId) return null;
  // A canvas whose control went to a Worker cannot be handed out again: a new session gets a new one.
  return (
    <canvas
      key={sessionId}
      ref={canvasRef}
      aria-hidden
      data-native-transcript=""
      style={{
        position: "fixed",
        pointerEvents: "none",
        zIndex: 5,
        visibility: atBottom ? "visible" : "hidden",
      }}
    />
  );
}
