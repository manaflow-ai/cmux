// A layer of soft light behind a surface's content (Home, New Tab), for depth: two blurred washes of
// the accent that sit at different depths. Not yet used by a surface; Home and New Tab adopt it after
// their migration lands.
//
// Looks (the gallery `ui.motion-depth-layer` compares them):
// - `still`: the washes, nothing moves.
// - `drift`: the washes drift once, slowly, after the surface shows, then rest. One CSS animation the
//   compositor runs, `iteration-count: 1`, DRIFT_S long; it does not loop.
// - `parallax`: the washes lean a few px toward the pointer, the far one less than the near one. Event
//   driven: each pointermove writes two custom properties and a transform transition (at most
//   --cmux-motion-large) carries the washes there; nothing runs while the pointer is still.
// - `drift-parallax`: both.
//
// Stop conditions: no timer and no frame loop. The drift ends after DRIFT_S and is paused while the
// page is hidden (one visibilitychange listener). The parallax runs only on pointer events over the
// surface and settles within 240 ms of the last one. Both listeners are removed on unmount. Motion off
// or Reduce Motion: still (CSS `prefers-reduced-motion` and the root's motion attributes), and no
// pointer listener.
import { type RefObject, useEffect, useRef } from "react";
import { cx } from "../cx";
import { motionMode } from "./motionMode";
import "./motion.css";

export type DepthLook = "still" | "drift" | "parallax" | "drift-parallax";

/** How long the one drift lasts (s): a loop by the motion scale's reading, so it is off the scale. */
export const DRIFT_S = 24;
/** The most the near wash leans toward the pointer (px); the far one leans half as far. */
export const PARALLAX_PX = 10;

export type DepthLayerProps = {
  look?: DepthLook;
  /** The surface whose pointer moves lean the washes; the layer's parent by default. */
  surface?: RefObject<HTMLElement | null>;
  className?: string;
};

export function DepthLayer({ look = "parallax", surface, className }: DepthLayerProps) {
  const layer = useRef<HTMLDivElement>(null);

  // Pause the drift while the page is hidden.
  useEffect(() => {
    const element = layer.current;
    if (!element || (look !== "drift" && look !== "drift-parallax")) return;
    const doc = element.ownerDocument;
    const sync = () => {
      if (doc.visibilityState === "hidden") element.dataset.paused = "";
      else delete element.dataset.paused;
    };
    sync();
    doc.addEventListener("visibilitychange", sync);
    return () => doc.removeEventListener("visibilitychange", sync);
  }, [look]);

  // Lean toward the pointer, on its events only.
  useEffect(() => {
    const element = layer.current;
    const target = surface?.current ?? element?.parentElement;
    if (!element || !target || (look !== "parallax" && look !== "drift-parallax")) return;
    if (motionMode(element.ownerDocument) !== "full") return;
    const lean = (event: PointerEvent) => {
      const box = target.getBoundingClientRect();
      if (box.width <= 0 || box.height <= 0) return;
      const x = ((event.clientX - box.left) / box.width) * 2 - 1;
      const y = ((event.clientY - box.top) / box.height) * 2 - 1;
      element.style.setProperty("--ui-depth-x", Math.max(-1, Math.min(1, x)).toFixed(3));
      element.style.setProperty("--ui-depth-y", Math.max(-1, Math.min(1, y)).toFixed(3));
    };
    const rest = () => {
      element.style.setProperty("--ui-depth-x", "0");
      element.style.setProperty("--ui-depth-y", "0");
    };
    target.addEventListener("pointermove", lean, { passive: true });
    target.addEventListener("pointerleave", rest, { passive: true });
    return () => {
      target.removeEventListener("pointermove", lean);
      target.removeEventListener("pointerleave", rest);
    };
  }, [look, surface]);

  return (
    <div
      ref={layer}
      className={cx("ui-depth", className)}
      data-look={look}
      style={{ ["--ui-depth-drift" as string]: `${DRIFT_S}s`, ["--ui-depth-lean" as string]: `${PARALLAX_PX}px` }}
      aria-hidden="true"
    >
      <span className="ui-depth__wash" data-depth="far" />
      <span className="ui-depth__wash" data-depth="near" />
    </div>
  );
}
