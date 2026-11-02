// Session Info's sections in the person's one order (sectionOrder.ts), every section movable anywhere
// in the panel, as Claude desktop's are (Leo, 2026-10-31: "THE CLICK DRAG" ... "WHERE IS MY FUCKING
// PARITY"; 2026-10-28: "the six dots or whatever, to, like, reorder and rearrange things with a nice
// little drag-and-drop thing").
//
// - Blocks: each section keeps the block it belongs to (where it runs, what it made, what it runs),
//   and a hairline sits wherever two adjacent sections come from different blocks. So the default
//   order draws the three blocks it always drew, pixel for pixel, and no section is ever a box.
// - Drag: the six-dot handle (SessionInfoSection's `ReorderHandle`) lifts the section. It follows the
//   pointer; once its middle passes a neighbour's middle the order changes, and the neighbours slide
//   out of the way (FLIP on `--cmux-motion-standard`, Web Animations on `transform` only). On release
//   it settles into its place on the same step and the order is saved; Escape puts it back where it
//   was. Up and Down Arrow on the focused handle move it one place, also animated, focus kept.
// - Stop and cleanup: every animation is a finite 180 ms Web Animation, cancelled when the section
//   moves again or the list unmounts; the window listeners exist only while a drag runs (pointer up,
//   pointer cancel, Escape and window blur end it). Reduce Motion or the host's motion switch
//   (`data-agent-motion="off"`) moves everything in one frame.
import { createContext, useContext, useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { MOTION_EASE_OUT, MOTION_MS } from "../../../motion/scale.generated";
import { isAgentMotionOff } from "../../shared/motion";
import { moveTo, sectionGroup, setSectionOrder, useSectionOrder } from "./sectionOrder";
import type { SessionInfoSectionId } from "./sessionInfoState";

type Reorder = {
  dragging: SessionInfoSectionId | undefined;
  start: (id: SessionInfoSectionId, event: React.PointerEvent<HTMLElement>) => void;
  step: (id: SessionInfoSectionId, by: -1 | 1) => void;
};

const ReorderContext = createContext<Reorder | undefined>(undefined);

/// The panel's reorder actions, for a section inside it; none outside (the gallery's lone sections).
export function useReorder(): Reorder | undefined {
  return useContext(ReorderContext);
}

type Drag = {
  id: SessionInfoSectionId;
  /// The pointer's clientY at the press and now.
  startY: number;
  y: number;
  /// The section's layout top in the list at the press, and the scroller's offset then.
  grabTop: number;
  startScroll: number;
  scroller: HTMLElement | null;
  /// The order when the drag began, for Escape.
  before: SessionInfoSectionId[];
};

/// How far below its top the held section looks for its place (at most its middle).
const PROBE = 24;

function motionOn(): boolean {
  if (isAgentMotionOff()) return false;
  return !(globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false);
}

/// The vertical shift a section is drawn with now (a running slide included).
function drawnShift(element: HTMLElement): number {
  const transform = getComputedStyle(element).transform;
  if (!transform || transform === "none") return 0;
  const match = /^matrix(?:3d)?\((.+)\)$/.exec(transform);
  if (!match) return 0;
  const values = match[1]!.split(",").map(Number);
  const y = transform.startsWith("matrix3d") ? values[13] : values[5];
  return Number.isFinite(y) ? (y as number) : 0;
}

/// Slides `node` from `from` px above or below its place into it; none where Web Animations is missing.
function slideFrom(node: HTMLElement, from: number): Animation | undefined {
  if (typeof node.animate !== "function") return undefined;
  return node.animate([{ transform: `translateY(${from}px)` }, { transform: "translateY(0)" }], {
    duration: MOTION_MS.standard,
    easing: MOTION_EASE_OUT,
  });
}

export function SessionInfoSectionList({
  sections,
}: {
  /// Every section by id; a falsy node is a section not shown.
  sections: Partial<Record<SessionInfoSectionId, ReactNode>>;
}) {
  const saved = useSectionOrder();
  // While a drag runs, the order it shows; saved when the drag ends.
  const [draft, setDraft] = useState<SessionInfoSectionId[]>();
  const [dragging, setDragging] = useState<SessionInfoSectionId>();
  const base = draft ? [...draft, ...saved.filter((id) => !draft.includes(id))] : saved;
  const shown = base.filter((id) => sections[id]);
  const list = useRef<HTMLDivElement>(null);
  const drag = useRef<Drag | undefined>(undefined);
  // Each section's layout top at the last commit, the order then, and the slides running.
  const places = useRef(new Map<SessionInfoSectionId, number>());
  const lastOrder = useRef<string>("");
  const slides = useRef(new Map<SessionInfoSectionId, Animation>());
  // The section to settle into its place (from where it is drawn), and the handle to keep focused.
  const settle = useRef<{ id: SessionInfoSectionId; top: number } | undefined>(undefined);
  const focus = useRef<SessionInfoSectionId | undefined>(undefined);

  const slot = (id: SessionInfoSectionId) =>
    list.current?.querySelector<HTMLElement>(`:scope > [data-slot="${id}"]`) ?? null;

  /// Draws the dragged section under the pointer, whatever its layout place now is.
  const follow = () => {
    const held = drag.current;
    const node = held && slot(held.id);
    if (!held || !node) return;
    const scrolled = (held.scroller?.scrollTop ?? 0) - held.startScroll;
    node.style.transform = `translateY(${held.grabTop + (held.y - held.startY) + scrolled - node.offsetTop}px)`;
  };

  useLayoutEffect(() => {
    const root = list.current;
    if (!root) return;
    const order = shown.join(" ");
    const moved = order !== lastOrder.current;
    lastOrder.current = order;
    const animate = motionOn();
    // A section that left keeps no place: shown again, it appears where it lands.
    for (const id of places.current.keys()) if (!shown.includes(id)) places.current.delete(id);
    for (const node of root.querySelectorAll<HTMLElement>(":scope > [data-slot]")) {
      const id = node.dataset.slot as SessionInfoSectionId;
      const top = node.offsetTop;
      const was = places.current.get(id);
      places.current.set(id, top);
      if (drag.current?.id === id) continue;
      if (settle.current?.id === id) {
        const from = settle.current.top - top;
        settle.current = undefined;
        node.style.transform = "";
        slides.current.get(id)?.cancel();
        if (!animate || from === 0) {
          delete node.dataset.settling;
          continue;
        }
        const slide = slideFrom(node, from);
        if (!slide) {
          delete node.dataset.settling;
          continue;
        }
        node.dataset.settling = "";
        slides.current.set(id, slide);
        const done = () => {
          if (slides.current.get(id) === slide) slides.current.delete(id);
          delete node.dataset.settling;
        };
        slide.onfinish = done;
        slide.oncancel = done;
        continue;
      }
      if (!moved || !animate || was === undefined || was === top) continue;
      // From where it is drawn now (its old place plus any slide still running) to its new place.
      const from = was + drawnShift(node) - top;
      slides.current.get(id)?.cancel();
      if (from === 0) continue;
      const slide = slideFrom(node, from);
      if (!slide) continue;
      slides.current.set(id, slide);
      slide.onfinish = () => {
        if (slides.current.get(id) === slide) slides.current.delete(id);
      };
    }
    follow();
    // React moves a section's node to reorder it, which drops the focus of its handle.
    const keep = focus.current;
    focus.current = undefined;
    const handle = keep && slot(keep)?.querySelector<HTMLElement>(".acpmux-session-info-section__handle");
    if (handle && handle.ownerDocument.activeElement !== handle) handle.focus({ preventScroll: true });
  });

  useEffect(() => {
    const running = slides.current;
    return () => {
      for (const slide of running.values()) slide.cancel();
      running.clear();
    };
  }, []);

  // The drag follows the pointer on the window, not the handle: moving the section moves the handle's
  // node, which would drop a pointer capture on it. The listeners go with the drag.
  useEffect(() => {
    if (!dragging) return;
    const end = (cancel: boolean) => {
      const held = drag.current;
      if (!held) return;
      const node = slot(held.id);
      // Where it is drawn now: the settle starts there.
      settle.current = { id: held.id, top: node ? node.offsetTop + drawnShift(node) : held.grabTop };
      drag.current = undefined;
      const final = cancel ? held.before : list.current ? shownNow() : held.before;
      if (!cancel) setSectionOrder(final);
      setDraft(undefined);
      setDragging(undefined);
    };
    const shownNow = () =>
      [...list.current!.querySelectorAll<HTMLElement>(":scope > [data-slot]")].map(
        (node) => node.dataset.slot as SessionInfoSectionId,
      );
    // Where the held section belongs now. It probes near its top, where the handle is, not at its
    // middle: a section taller than the panel could never carry its middle above the first one.
    const place = () => {
      const held = drag.current;
      const root = list.current;
      if (!held || !root) return;
      follow();
      const node = slot(held.id);
      if (!node) return;
      const scrolled = (held.scroller?.scrollTop ?? 0) - held.startScroll;
      const probe = held.grabTop + (held.y - held.startY) + scrolled + Math.min(node.offsetHeight / 2, PROBE);
      const others = shownNow().filter((id) => id !== held.id);
      const at = others.filter((id) => {
        const other = slot(id)!;
        return other.offsetTop + other.offsetHeight / 2 < probe;
      }).length;
      const next = moveTo(others, held.id, at);
      setDraft((current) => (current && current.join(" ") === next.join(" ") ? current : next));
    };
    const move = (event: PointerEvent) => {
      if (!drag.current) return;
      drag.current.y = event.clientY;
      place();
    };
    const up = () => end(false);
    const key = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      event.stopPropagation();
      end(true);
    };
    // Scrolling under a still pointer carries the section past its neighbours too.
    const scroll = () => place();
    const scroller = drag.current?.scroller;
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
    window.addEventListener("pointercancel", up);
    window.addEventListener("blur", up);
    window.addEventListener("keydown", key, true);
    scroller?.addEventListener("scroll", scroll, { passive: true });
    return () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
      window.removeEventListener("pointercancel", up);
      window.removeEventListener("blur", up);
      window.removeEventListener("keydown", key, true);
      scroller?.removeEventListener("scroll", scroll);
    };
    // `slot` and `follow` read refs only.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [dragging]);

  const reorder: Reorder = {
    dragging,
    start: (id, event) => {
      if (event.button !== 0) return;
      const node = slot(id);
      if (!node) return;
      event.preventDefault();
      slides.current.get(id)?.cancel();
      const scroller = node.closest<HTMLElement>(".acpmux-session-info__body");
      drag.current = {
        id,
        startY: event.clientY,
        y: event.clientY,
        grabTop: node.offsetTop,
        startScroll: scroller?.scrollTop ?? 0,
        scroller,
        before: shown,
      };
      setDraft(shown);
      setDragging(id);
    },
    step: (id, by) => {
      const at = shown.indexOf(id);
      const to = at + by;
      // A pointer drag owns the order until it drops or Escape puts it back.
      if (drag.current || at < 0 || to < 0 || to >= shown.length) return;
      focus.current = id;
      setSectionOrder(moveTo(shown, id, to));
    },
  };

  return (
    <div ref={list} className="acpmux-session-info-sections" data-dragging={dragging ? "" : undefined}>
      <ReorderContext.Provider value={shown.length > 1 ? reorder : undefined}>
        {shown.map((id, at) => {
          const group = sectionGroup(id);
          const prior = shown[at - 1];
          const next = shown[at + 1];
          return (
            <div
              key={id}
              className="acpmux-session-info-slot"
              data-slot={id}
              data-group={group}
              data-run-start={prior && sectionGroup(prior) !== group ? "" : undefined}
              data-run-end={next && sectionGroup(next) !== group ? "" : undefined}
              data-lifted={dragging === id ? "" : undefined}
            >
              {sections[id]}
            </div>
          );
        })}
      </ReorderContext.Provider>
    </div>
  );
}
