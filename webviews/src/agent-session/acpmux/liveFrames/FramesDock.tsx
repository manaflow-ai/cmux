// The preview window: a floating panel inside the agent pane that shows the chat's newest frame
// live. Drag it by its header, resize it from the corner, collapse it to a pill, expand it to
// fill the pane, hide it. Its place, size and state persist per pane (dockState.ts). It appears
// only once the chat has a frame, and polls for the newest one only while a turn runs and the
// window is on screen. Pure CSS and pointer events.
// Leo, 2026-11-24: "we can also drag and shrink and expand and hide the preview window".
import { useCallback, useEffect, useReducer, useRef, useState, type PointerEvent as ReactPointerEvent } from "react";
import { useT } from "../i18n";
import {
  dockReducer,
  initialDock,
  loadDock,
  saveDock,
  shownSize,
  type Bounds,
  type DockMode,
  type DockState,
} from "./dockState";
import type { TurnFrame } from "./turnFrames";
import "./liveFrames.css";

export type LatestFrame = (sinceSeq: number) => Promise<{ frame?: TurnFrame; seq: number }>;
const POLL_MS = 1500;

export function FramesDock({
  pane,
  latest,
  working,
  onOpen,
}: {
  /// Names this pane's saved place.
  pane: string;
  /// The newest frame since a seq; absent where acpmux has no frames (nothing draws).
  latest: LatestFrame | undefined;
  /// A turn is running: the only time the window polls.
  working: boolean;
  onOpen?: (src: string, alt: string) => void;
}) {
  const t = useT();
  const layer = useRef<HTMLDivElement>(null);
  const [frame, setFrame] = useState<TurnFrame>();
  const hasFrame = frame !== undefined;
  const seq = useRef(0);
  const bounds = (): Bounds => {
    const box = layer.current?.getBoundingClientRect();
    return { width: box?.width || 600, height: box?.height || 400 };
  };
  const [dock, dispatch] = useReducer(
    dockReducer,
    undefined,
    (): DockState => loadDock(pane) ?? initialDock({ width: 600, height: 700 }),
  );
  const loaded = useRef(false);
  // The first measure: a place never saved is the pane's corner; a saved one is fitted to the pane.
  useEffect(() => {
    if (loaded.current || !frame) return;
    loaded.current = true;
    dispatch({ type: "fit", pane: bounds() });
  }, [frame]);
  useEffect(() => {
    saveDock(pane, dock);
  }, [pane, dock]);
  useEffect(() => {
    const element = layer.current;
    if (!element || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(() => dispatch({ type: "fit", pane: bounds() }));
    observer.observe(element);
    return () => observer.disconnect();
  }, [hasFrame]);

  // A new chat starts from its own frames.
  useEffect(() => {
    seq.current = 0;
    setFrame(undefined);
  }, [pane, latest]);
  const pull = useCallback(async () => {
    if (!latest) return;
    try {
      const next = await latest(seq.current);
      seq.current = next.seq;
      if (next.frame) setFrame(next.frame);
    } catch {
      // The next tick asks again.
    }
  }, [latest]);
  // One read to learn whether the chat has any frame at all (the window appears only then).
  useEffect(() => {
    void pull();
  }, [pull]);
  // A turn starting brings a hidden window back as its pill.
  const wasWorking = useRef(false);
  useEffect(() => {
    if (working && !wasWorking.current && dock.mode === "hidden") dispatch({ type: "mode", mode: "pill" });
    wasWorking.current = working;
  }, [working, dock.mode]);
  const visible = frame !== undefined && dock.mode !== "hidden";
  // Live: poll only while a turn runs and the window shows.
  useEffect(() => {
    if (!working || !visible) return;
    const timer = setInterval(() => void pull(), POLL_MS);
    void pull();
    return () => clearInterval(timer);
  }, [working, visible, pull]);

  const drag = useRef<{ x: number; y: number; kind: "move" | "resize" }>(null);
  const begin = (kind: "move" | "resize") => (event: ReactPointerEvent<HTMLElement>) => {
    if (event.button !== 0 || dock.mode === "full") return;
    if (kind === "move" && (event.target as HTMLElement).closest("button")) return;
    drag.current = { x: event.clientX, y: event.clientY, kind };
    event.currentTarget.setPointerCapture(event.pointerId);
    event.preventDefault();
  };
  const track = (event: ReactPointerEvent<HTMLElement>) => {
    const from = drag.current;
    if (!from) return;
    const dx = event.clientX - from.x;
    const dy = event.clientY - from.y;
    drag.current = { ...from, x: event.clientX, y: event.clientY };
    dispatch(
      from.kind === "move"
        ? { type: "move", dx, dy, pane: bounds() }
        : { type: "resize", dw: dx, dh: dy, pane: bounds() },
    );
  };
  const end = (event: ReactPointerEvent<HTMLElement>) => {
    drag.current = null;
    if (event.currentTarget.hasPointerCapture(event.pointerId))
      event.currentTarget.releasePointerCapture(event.pointerId);
  };
  const mode = (next: DockMode) => () => dispatch({ type: "mode", mode: next });

  if (!latest || !frame || dock.mode === "hidden") return null;
  const title = t("header.preview");
  const size = shownSize(dock);
  const full = dock.mode === "full";
  const style = full
    ? undefined
    : { transform: `translate(${dock.x}px, ${dock.y}px)`, width: size.width, height: size.height };
  return (
    <div ref={layer} className="acpmux-frames-dock-layer">
      <section className="acpmux-frames-dock ui-glass" data-mode={dock.mode} style={style} aria-label={title}>
        <header
          className="acpmux-frames-dock__head"
          onPointerDown={begin("move")}
          onPointerMove={track}
          onPointerUp={end}
          onPointerCancel={end}
          onDoubleClick={mode(dock.mode === "pill" ? "open" : "pill")}
        >
          <span className="acpmux-frames-dock__title">{title}</span>
          <button
            type="button"
            className="acpmux-frames-dock__button"
            aria-label={t(dock.mode === "pill" ? "render.expand" : "render.collapse")}
            title={t(dock.mode === "pill" ? "render.expand" : "render.collapse")}
            onClick={mode(dock.mode === "pill" ? "open" : "pill")}
          >
            {dock.mode === "pill" ? "▢" : "–"}
          </button>
          {dock.mode !== "pill" && (
            <button
              type="button"
              className="acpmux-frames-dock__button"
              aria-label={t(full ? "render.collapse" : "render.expand")}
              title={t(full ? "render.collapse" : "render.expand")}
              onClick={mode(full ? "open" : "full")}
            >
              {full ? "⤡" : "⤢"}
            </button>
          )}
          <button
            type="button"
            className="acpmux-frames-dock__button"
            aria-label={t("managed.hide")}
            title={t("managed.hide")}
            onClick={mode("hidden")}
          >
            ×
          </button>
        </header>
        {dock.mode !== "pill" && (
          <button
            type="button"
            className="acpmux-frames-dock__body"
            onClick={() => onOpen?.(frame.full, title)}
            disabled={!onOpen}
          >
            <img src={frame.full} alt={title} draggable={false} />
          </button>
        )}
        {dock.mode === "open" && (
          <hr
            className="acpmux-frames-dock__grip"
            aria-label={t("turnFrames.resize")}
            onPointerDown={begin("resize")}
            onPointerMove={track}
            onPointerUp={end}
            onPointerCancel={end}
          />
        )}
      </section>
    </div>
  );
}
