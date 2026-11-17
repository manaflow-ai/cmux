import { type ReactNode, useLayoutEffect, useState } from "react";
import { createPortal } from "react-dom";
import { OVER_COPY_ATTRIBUTE } from "./chatSnapshot/live";

/// How far the live composer's top edge is from the window's bottom, in CSS pixels: where the
/// copy's own composer starts too, since a copy is drawn only at the size it was written at
/// (chatSnapshot/shared.ts). 0 without a composer.
function composerRise(doc: Document): number {
  const composer = doc.querySelector("#root .acpmux-composer");
  const view = doc.defaultView;
  if (!composer || !view) return 0;
  return Math.max(0, view.innerHeight - composer.getBoundingClientRect().top);
}

/// The host failure's line while the last launch's copy of the chat still shows (firstPaint.ts:
/// a said failure no longer takes the copy off). The live page is at opacity 0 under the copy, so
/// the line is drawn outside it, above the copy, standing on the composer's top edge over the
/// copy's last rows: nothing in the copy or the live page moves for it, and its Retry takes its
/// own presses (chatSnapshot/live.ts `OVER_COPY_ATTRIBUTE`). The copy goes once the chat's rows
/// draw, and the line with it once the retry connects (Leo, 2026-11-16: "it said something went
/// wrong with a retry button ... and then it layout shifted").
export function HostLineOverCopy({ children, doc = document }: { children: ReactNode; doc?: Document }) {
  const [bottom, setBottom] = useState(() => composerRise(doc));
  useLayoutEffect(() => {
    const view = doc.defaultView;
    const measure = () => setBottom(composerRise(doc));
    measure();
    view?.addEventListener("resize", measure);
    const composer = doc.querySelector("#root .acpmux-composer");
    const observer = composer && typeof ResizeObserver !== "undefined" ? new ResizeObserver(measure) : undefined;
    if (composer) observer?.observe(composer);
    return () => {
      view?.removeEventListener("resize", measure);
      observer?.disconnect();
    };
  }, [doc]);
  return createPortal(
    <div className="acpmux-host-line-over-copy" {...{ [OVER_COPY_ATTRIBUTE]: "" }} style={{ bottom }}>
      {children}
    </div>,
    doc.body,
  );
}
