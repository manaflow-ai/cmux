// An opened run of calls (ToolRun.tsx, ToolGroupRow.tsx) as the Codex app draws a long one: 14
// lines that scroll on their own, faded at the top and bottom where more is hidden
// (runScroll.experiment.ts; Lucas, 2026-11-11). A short run draws as before: no fade, nothing to scroll.
import { useCallback, useContext, useLayoutEffect, useRef, type ReactNode } from "react";
import { experimentArm } from "../../../experiments/experiment";
import { FindReveal } from "./chatFind";
import { runScroll } from "./runScroll.experiment";

/// The fades say where more is hidden: `data-fade-top` once scrolled down, `data-fade-bottom` while
/// more is under the box. Written on the box itself, so a scroll draws the run again never.
/// `follow`: while a call runs, a box at its end stays at its end as lines arrive.
function useScrollFades(follow: boolean) {
  const box = useRef<HTMLDivElement>(null);
  const content = useRef<HTMLDivElement>(null);
  const atEnd = useRef(true);
  const following = useRef(follow);
  following.current = follow;
  const mark = useCallback(() => {
    const node = box.current;
    if (!node) return;
    const end = node.scrollHeight - node.clientHeight;
    node.toggleAttribute("data-fade-top", node.scrollTop > 1);
    node.toggleAttribute("data-fade-bottom", node.scrollTop < end - 1);
    atEnd.current = node.scrollTop >= end - 1;
  }, []);
  // Lines arrive, or one inside opens, without a scroll: the content's size says so.
  useLayoutEffect(() => {
    const node = box.current;
    const inner = content.current;
    if (!node || !inner || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(() => {
      if (following.current && atEnd.current) node.scrollTop = node.scrollHeight;
      mark();
    });
    observer.observe(inner);
    return () => observer.disconnect();
  }, [mark]);
  return { box, content, mark };
}

/// The running line's count names a call (FindReveal `toolId`, WorkingFor.tsx): the transcript
/// scrolls its row in, and the box scrolls the call in, a third down, as Find does a match. A text
/// match scrolls itself in through the boxes around it (VirtualTranscript.tsx `scrollRangeInBoxes`).
function useRevealCall(box: { current: HTMLDivElement | null }, mark: () => void) {
  const toolId = useContext(FindReveal)?.toolId;
  useLayoutEffect(() => {
    const node = box.current;
    if (!node || toolId === undefined) return;
    const call = [...node.querySelectorAll<HTMLElement>("[data-tool-id]")].find(
      (element) => element.dataset.toolId === toolId,
    );
    if (!call) return;
    const top = call.getBoundingClientRect().top - node.getBoundingClientRect().top + node.scrollTop;
    node.scrollTop = Math.max(0, top - node.clientHeight / 3);
    mark();
  }, [box, mark, toolId]);
}

export function RunScroll({ running = false, children }: { running?: boolean; children: ReactNode }) {
  const { box, content, mark } = useScrollFades(running);
  useRevealCall(box, mark);
  if (experimentArm(runScroll) !== "box") return children;
  return (
    <div ref={box} className="cv-run-scroll" onScroll={mark}>
      <div ref={content}>{children}</div>
    </div>
  );
}
