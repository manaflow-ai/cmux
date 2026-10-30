// Zoom and pan for an image on a stage: a pinch (WebKit's gesture events, or a wheel event with
// Control elsewhere) or Command-scroll zooms about the pointer, a scroll or a drag pans a zoomed
// image, and a double click zooms in or back to the fitted size. The chat's image viewer
// (agent-session/acpmux/conversation/ImageViewer.tsx) and Agent Activity's frame viewer
// (agent-activity/viewer.tsx) share it. The view is a transform for the image: `scale` from the
// fitted size, `x`/`y` its offset from the stage's center.
import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type MouseEvent as ReactMouseEvent,
  type PointerEvent as ReactPointerEvent,
} from "react";

export const MIN_SCALE = 1;
export const MAX_SCALE = 8;
/// What a double click or the + key zooms to from the fitted image.
export const ZOOM_STEP = 2;

export type ZoomView = { scale: number; x: number; y: number };
export const FIT: ZoomView = { scale: 1, x: 0, y: 0 };

/// `view` zoomed to `scale` about `point` (relative to the stage's center), so the pixel under
/// the point stays there. Back at the fitted size the image is centered again.
export function zoomAbout(view: ZoomView, scale: number, point: { x: number; y: number }): ZoomView {
  const next = Math.min(MAX_SCALE, Math.max(MIN_SCALE, scale));
  if (next === MIN_SCALE) return FIT;
  const ratio = next / view.scale;
  return { scale: next, x: point.x - (point.x - view.x) * ratio, y: point.y - (point.y - view.y) * ratio };
}

/// The CSS transform that draws `view`.
export const zoomTransform = (view: ZoomView) => `translate(${view.x}px, ${view.y}px) scale(${view.scale})`;

/// The stage's zoom and pan. `stageRef` goes on the stage element (it may mount after the first
/// commit, inside a dialog's portal: the pinch and wheel listeners attach once it is there), and
/// `stageHandlers` on the same element.
export function useZoomPan() {
  const [view, setView] = useState<ZoomView>(FIT);
  // The view a pinch started from, read by the gesture listener (registered once).
  const viewRef = useRef(view);
  useEffect(() => {
    viewRef.current = view;
  }, [view]);
  const stage = useRef<HTMLElement | null>(null);
  const [stageElement, setStageElement] = useState<HTMLElement | null>(null);
  const stageRef = useCallback((element: HTMLElement | null) => {
    stage.current = element;
    setStageElement(element);
  }, []);
  const drag = useRef<{ id: number; x: number; y: number } | undefined>(undefined);

  const center = () => {
    const box = stage.current?.getBoundingClientRect();
    return box ? { x: box.left + box.width / 2, y: box.top + box.height / 2 } : { x: 0, y: 0 };
  };
  const fromCenter = (clientX: number, clientY: number) => {
    const c = center();
    return { x: clientX - c.x, y: clientY - c.y };
  };

  // A pinch zooms about the pointer: WebKit sends it as gesture events, other engines as a wheel
  // event with Control. Command-scroll zooms too; a scroll pans a zoomed image. The listeners are
  // not passive, so the pane never scrolls or magnifies behind.
  useEffect(() => {
    const element = stageElement;
    if (!element) return;
    let pinchFrom: ZoomView | undefined;
    const onGesture = (event: Event) => {
      event.preventDefault();
      const gesture = event as Event & { scale?: number; clientX?: number; clientY?: number };
      if (event.type === "gesturestart") pinchFrom = viewRef.current;
      else if (event.type === "gesturechange" && pinchFrom && typeof gesture.scale === "number") {
        const from = pinchFrom;
        const point = fromCenter(gesture.clientX ?? center().x, gesture.clientY ?? center().y);
        setView(zoomAbout(from, from.scale * gesture.scale, point));
      } else if (event.type === "gestureend") pinchFrom = undefined;
    };
    for (const type of ["gesturestart", "gesturechange", "gestureend"]) element.addEventListener(type, onGesture);
    const onWheel = (event: WheelEvent) => {
      event.preventDefault();
      if (event.ctrlKey || event.metaKey) {
        const point = fromCenter(event.clientX, event.clientY);
        setView((current) => zoomAbout(current, current.scale * Math.exp(-event.deltaY * 0.01), point));
      } else
        setView((current) =>
          current.scale === MIN_SCALE
            ? current
            : { ...current, x: current.x - event.deltaX, y: current.y - event.deltaY },
        );
    };
    element.addEventListener("wheel", onWheel, { passive: false });
    return () => {
      element.removeEventListener("wheel", onWheel);
      for (const type of ["gesturestart", "gesturechange", "gestureend"]) element.removeEventListener(type, onGesture);
    };
  }, [stageElement]);

  const onPointerDown = (event: ReactPointerEvent) => {
    if (view.scale === MIN_SCALE || event.button !== 0) return;
    event.currentTarget.setPointerCapture(event.pointerId);
    drag.current = { id: event.pointerId, x: event.clientX, y: event.clientY };
  };
  const onPointerMove = (event: ReactPointerEvent) => {
    const from = drag.current;
    if (!from || from.id !== event.pointerId) return;
    drag.current = { ...from, x: event.clientX, y: event.clientY };
    setView((current) => ({
      ...current,
      x: current.x + event.clientX - from.x,
      y: current.y + event.clientY - from.y,
    }));
  };
  const endDrag = () => (drag.current = undefined);
  const onDoubleClick = (event: ReactMouseEvent) => {
    const point = fromCenter(event.clientX, event.clientY);
    setView((current) => (current.scale > MIN_SCALE ? FIT : zoomAbout(current, ZOOM_STEP, point)));
  };

  return {
    view,
    setView,
    stageRef,
    stageHandlers: { onPointerDown, onPointerMove, onPointerUp: endDrag, onPointerCancel: endDrag, onDoubleClick },
  };
}
