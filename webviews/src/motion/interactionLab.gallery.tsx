import { useEffect, useRef, useState } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";

type DemoKind = "hierarchy" | "list" | "gesture" | "interrupt" | "reduced";
type StageProps = { kind: DemoKind };

type Cleanup = () => void;

/** Keep every demo's side effects in one bounded registry. A new intent cancels old work first. */
function useCleanupRegistry() {
  const cleanups = useRef<Set<Cleanup>>(new Set());
  const add = (cleanup: Cleanup) => {
    cleanups.current.add(cleanup);
    return () => cleanups.current.delete(cleanup);
  };
  useEffect(() => {
    const stopAll = () => {
      for (const cleanup of cleanups.current) cleanup();
      cleanups.current.clear();
    };
    const root = typeof document === "undefined" ? null : document.documentElement;
    const observer = root
      ? new MutationObserver(() => {
          const setting = root.dataset.cmuxMotion;
          if (setting === "reduced" || setting === "off") stopAll();
        })
      : null;
    if (root && observer) observer.observe(root, { attributes: true, attributeFilter: ["data-cmux-motion"] });
    return () => {
      observer?.disconnect();
      stopAll();
    };
  }, []);
  return { add };
}

function useReducedMotion() {
  const [reduced, setReduced] = useState(false);
  useEffect(() => {
    const query = window.matchMedia("(prefers-reduced-motion: reduce)");
    const update = () => {
      const setting = document.documentElement.dataset.cmuxMotion;
      setReduced(query.matches || setting === "reduce" || setting === "reduced" || setting === "off");
    };
    update();
    query.addEventListener("change", update);
    const observer = new MutationObserver(update);
    observer.observe(document.documentElement, { attributes: true, attributeFilter: ["data-cmux-motion"] });
    return () => {
      query.removeEventListener("change", update);
      observer.disconnect();
    };
  }, []);
  return reduced;
}

function stageTiming(reduced: boolean, duration = 360) {
  return reduced ? 0 : duration;
}

function cancelAnimations(element: Element | null): void {
  for (const animation of element?.getAnimations() ?? []) animation.cancel();
}

function motionSurface(element: Element | null): HTMLElement | null {
  return element?.closest<HTMLElement>("[data-motion-demo]") ?? null;
}

function motionIsOff(): boolean {
  return document.documentElement.dataset.cmuxMotion === "off";
}

function trackAnimations(animations: Animation[], add: (cleanup: Cleanup) => () => boolean) {
  if (!animations.length) return;
  const stop = () => animations.forEach((animation) => animation.cancel());
  const remove = add(stop);
  void Promise.allSettled(animations.map((animation) => animation.finished)).then(() => {
    remove();
    stop();
  });
}

function HierarchyDemo() {
  const reduced = useReducedMotion();
  const [open, setOpen] = useState(false);
  const cleanup = useCleanupRegistry();
  const panel = useRef<HTMLDivElement>(null);
  const title = useRef<HTMLHeadingElement>(null);
  const toggle = () => {
    const node = panel.current;
    if (!node) return;
    const surface = motionSurface(node);
    surface?.setAttribute("data-motion-active", "true");
    cancelAnimations(node);
    cancelAnimations(title.current);
    const next = !open;
    setOpen(next);
    if (motionIsOff()) {
      surface?.setAttribute("data-motion-active", "false");
      return;
    }
    let removeFrame = () => false;
    const frame = requestAnimationFrame(() => {
      removeFrame();
      if (!node) return;
      const duration = stageTiming(reduced, 360);
      const animation = node.animate(
        next
          ? [
              { opacity: 0, transform: "translateY(-12px) scale(.98)" },
              { opacity: 1, transform: "none" },
            ]
          : [
              { opacity: 1, transform: "none" },
              { opacity: 0, transform: "translateY(-12px) scale(.98)" },
            ],
        { duration, easing: "cubic-bezier(.2,.8,.2,1)", fill: "both" },
      );
      const titleAnimation = title.current?.animate(
        next
          ? [{ transform: "translateX(-10px)" }, { transform: "none" }]
          : [{ transform: "none" }, { transform: "translateX(-10px)" }],
        { duration, easing: "cubic-bezier(.2,.8,.2,1)", fill: "both" },
      );
      const stop = () => {
        animation.cancel();
        titleAnimation?.cancel();
        node.style.removeProperty("opacity");
        node.style.removeProperty("transform");
        surface?.setAttribute("data-motion-active", "false");
      };
      const remove = cleanup.add(stop);
      void animation.finished
        .then(() => {
          remove();
          stop();
        })
        .catch(() => {
          remove();
        });
    });
    removeFrame = cleanup.add(() => {
      cancelAnimationFrame(frame);
      surface?.setAttribute("data-motion-active", "false");
    });
  };
  return (
    <section
      className="il-card il-hierarchy"
      data-motion-demo="hierarchy"
      data-motion-active="false"
      data-motion-reduced={reduced}
    >
      <div className="il-copy">
        <span className="il-kicker">Parent → child</span>
        <h2 ref={title}>Workspace details</h2>
        <p>Shared title focus keeps the child panel spatially attached to its parent.</p>
        <button type="button" onClick={toggle} aria-expanded={open}>
          {open ? "Close details" : "Open details"}
        </button>
      </div>
      <div ref={panel} className="il-child" aria-hidden={!open} data-motion-child="panel">
        <strong>Build preview</strong>
        <span>Last checked just now</span>
        <span className="il-meter">
          <i />
        </span>
      </div>
    </section>
  );
}

function ListDemo() {
  const reduced = useReducedMotion();
  const [items, setItems] = useState(() => ["alpha", "bravo", "charlie"]);
  const list = useRef<HTMLUListElement>(null);
  const cleanup = useCleanupRegistry();
  const animateLayout = (before: Map<string, DOMRect>) => {
    if (reduced || motionIsOff()) return;
    const nodes = Array.from(list.current?.children ?? []) as HTMLElement[];
    const animations: Animation[] = [];
    nodes.forEach((node, index) => {
      const id = node.dataset.id ?? "";
      const first = before.get(id);
      const last = node.getBoundingClientRect();
      if (!first) {
        animations.push(
          node.animate(
            reduced
              ? [{ opacity: 0 }, { opacity: 1 }]
              : [
                  { opacity: 0, transform: "translateY(-14px) scale(.96)" },
                  { opacity: 1, transform: "none" },
                ],
            {
              duration: stageTiming(reduced, 300),
              delay: reduced ? 0 : index * 55,
              easing: "cubic-bezier(.2,.8,.2,1)",
            },
          ),
        );
        return;
      }
      const dx = first.left - last.left;
      const dy = first.top - last.top;
      if (Math.abs(dx) + Math.abs(dy) > 0.5)
        animations.push(
          node.animate([{ transform: `translate(${dx}px, ${dy}px)` }, { transform: "none" }], {
            duration: stageTiming(reduced, 320),
            easing: "cubic-bezier(.2,.8,.2,1)",
          }),
        );
    });
    if (animations.length) motionSurface(list.current)?.setAttribute("data-motion-active", "true");
    else motionSurface(list.current)?.setAttribute("data-motion-active", "false");
    trackAnimations(animations, (stop) => {
      const remove = cleanup.add(() => {
        stop();
        motionSurface(list.current)?.setAttribute("data-motion-active", "false");
      });
      return remove;
    });
  };
  const insert = () => {
    const before = new Map(
      Array.from(list.current?.children ?? []).map((node) => [
        node.getAttribute("data-id") ?? "",
        (node as HTMLElement).getBoundingClientRect(),
      ]),
    );
    // Two rows make the stagger visible while keeping the fixture small enough for a frame trace.
    setItems((current) => [`delta-${current.length + 1}`, `echo-${current.length + 1}`, ...current]);
    if (reduced || motionIsOff()) return;
    let removeFrame = () => false;
    const frame = requestAnimationFrame(() => {
      removeFrame();
      animateLayout(before);
    });
    removeFrame = cleanup.add(() => cancelAnimationFrame(frame));
  };
  const remove = () => {
    if (items.length < 2) return;
    const before = new Map(
      Array.from(list.current?.children ?? []).map((node) => [
        node.getAttribute("data-id") ?? "",
        (node as HTMLElement).getBoundingClientRect(),
      ]),
    );
    const target = list.current?.lastElementChild as HTMLElement | null;
    if (!target || reduced || motionIsOff()) {
      setItems((current) => current.slice(0, -1));
      return;
    }
    const animation = target.animate(
      [
        { opacity: 1, transform: "none" },
        { opacity: 0, transform: "translateX(24px) scale(.96)" },
      ],
      { duration: 220, easing: "cubic-bezier(.4,0,1,1)", fill: "forwards" },
    );
    motionSurface(list.current)?.setAttribute("data-motion-active", "true");
    const removeCleanup = cleanup.add(() => animation.cancel());
    void animation.finished
      .then(() => {
        removeCleanup();
        setItems((current) => current.slice(0, -1));
        let removeFrame = () => false;
        const frame = requestAnimationFrame(() => {
          removeFrame();
          animateLayout(before);
        });
        removeFrame = cleanup.add(() => cancelAnimationFrame(frame));
      })
      .catch(() => removeCleanup());
  };
  return (
    <section className="il-card" data-motion-demo="list" data-motion-active="false" data-motion-reduced={reduced}>
      <div className="il-copy">
        <span className="il-kicker">FLIP + stagger</span>
        <h2>Recent workspaces</h2>
        <p>Reads happen before writes; inserts reveal at 55ms intervals.</p>
        <div className="il-actions">
          <button type="button" onClick={insert}>
            Insert
          </button>
          <button type="button" onClick={remove} disabled={items.length < 2}>
            Remove
          </button>
        </div>
      </div>
      <ul ref={list} className="il-list" aria-label="Recent workspaces">
        {items.map((item) => (
          <li key={item} data-id={item}>
            <span className="il-dot" />
            {item}
          </li>
        ))}
      </ul>
    </section>
  );
}

function GestureDemo() {
  const reduced = useReducedMotion();
  const cleanup = useCleanupRegistry();
  const tile = useRef<HTMLButtonElement>(null);
  const drag = useRef<{
    pointer: number;
    x: number;
    lastX: number;
    lastT: number;
    velocity: number;
    frame?: number;
    release?: number;
  } | null>(null);
  const springFrame = useRef<number | undefined>(undefined);
  const runningStop = useRef<(() => void) | null>(null);
  const [x, setX] = useState(0);
  const onDown = (event: React.PointerEvent<HTMLButtonElement>) => {
    const node = tile.current;
    if (!node) return;
    runningStop.current?.();
    runningStop.current = null;
    if (springFrame.current !== undefined) cancelAnimationFrame(springFrame.current);
    node.setPointerCapture(event.pointerId);
    const now = performance.now();
    drag.current = { pointer: event.pointerId, x, lastX: event.clientX, lastT: now, velocity: 0 };
    for (const animation of node.getAnimations()) animation.cancel();
  };
  const onMove = (event: React.PointerEvent<HTMLButtonElement>) => {
    const state = drag.current;
    if (!state || state.pointer !== event.pointerId) return;
    const now = performance.now();
    const dt = Math.max(1, now - state.lastT);
    const delta = event.clientX - state.lastX;
    state.velocity = delta / dt;
    state.x = Math.max(-120, Math.min(120, state.x + delta));
    state.lastX = event.clientX;
    state.lastT = now;
    setX(state.x);
  };
  const onUp = (event: React.PointerEvent<HTMLButtonElement>) => {
    const node = tile.current;
    const state = drag.current;
    if (!node || !state || state.pointer !== event.pointerId) return;
    if (node.hasPointerCapture(event.pointerId)) node.releasePointerCapture(event.pointerId);
    drag.current = null;
    const surface = node.closest<HTMLElement>("[data-motion-demo]");
    if (reduced || motionIsOff()) {
      setX(0);
      surface?.setAttribute("data-motion-active", "false");
      return;
    }
    surface?.setAttribute("data-motion-active", "true");
    const start = state.x;
    const velocity = reduced ? 0 : state.velocity * 1000;
    const started = performance.now();
    const tick = (time: number) => {
      const elapsed = time - started;
      const t = Math.min(1, elapsed / 850);
      const spring = Math.exp(-6 * t) * Math.cos(12 * t) * velocity * 0.07;
      const next = Math.max(-140, Math.min(140, start * (1 - t) + spring * (1 - t)));
      setX(next);
      if (t < 1 && (Math.abs(next) > 0.2 || Math.abs(spring) > 0.2)) springFrame.current = requestAnimationFrame(tick);
      else {
        springFrame.current = undefined;
        setX(0);
        surface?.setAttribute("data-motion-active", "false");
        if (runningStop.current === stop) runningStop.current = null;
        removeCleanup();
      }
    };
    let removeCleanup = () => false;
    const stop = () => {
      if (springFrame.current !== undefined) cancelAnimationFrame(springFrame.current);
      springFrame.current = undefined;
      setX(0);
      surface?.setAttribute("data-motion-active", "false");
      if (runningStop.current === stop) runningStop.current = null;
      removeCleanup();
    };
    removeCleanup = cleanup.add(stop);
    runningStop.current = stop;
    springFrame.current = requestAnimationFrame(tick);
  };
  return (
    <section className="il-card" data-motion-demo="gesture" data-motion-active="false" data-motion-reduced={reduced}>
      <div className="il-copy">
        <span className="il-kicker">Gesture → spring</span>
        <h2>Follow-through tile</h2>
        <p>Pointer capture hands release velocity to a bounded spring. Escape by releasing or cancelling.</p>
      </div>
      <div className="il-gesture-track">
        <button
          ref={tile}
          type="button"
          className="il-tile"
          style={{ transform: `translateX(${x}px)` }}
          onPointerDown={onDown}
          onPointerMove={onMove}
          onPointerUp={onUp}
          onPointerCancel={onUp}
          aria-label="Drag preview"
        >
          Drag me
        </button>
      </div>
    </section>
  );
}

function InterruptDemo() {
  const reduced = useReducedMotion();
  const cleanup = useCleanupRegistry();
  const [open, setOpen] = useState(false);
  const panel = useRef<HTMLDivElement>(null);
  const toggle = () => {
    const node = panel.current;
    if (!node) return;
    const surface = motionSurface(node);
    surface?.setAttribute("data-motion-active", "true");
    const running = node.getAnimations()[0];
    const next = !open;
    if (motionIsOff()) {
      setOpen(next);
      surface?.setAttribute("data-motion-active", "false");
      return;
    }
    if (running) running.reverse();
    else {
      const animation = node.animate(
        open
          ? [
              { opacity: 1, transform: "none" },
              { opacity: 0, transform: "translateY(-18px)" },
            ]
          : [
              { opacity: 0, transform: "translateY(-18px)" },
              { opacity: 1, transform: "none" },
            ],
        { duration: stageTiming(reduced, 500), easing: "cubic-bezier(.2,.8,.2,1)", fill: "both" },
      );
      const stop = () => {
        animation.cancel();
        node.style.removeProperty("opacity");
        node.style.removeProperty("transform");
        surface?.setAttribute("data-motion-active", "false");
      };
      const remove = cleanup.add(stop);
      void animation.finished
        .then(() => {
          remove();
          stop();
        })
        .catch(() => remove());
    }
    setOpen(next);
  };
  return (
    <section className="il-card" data-motion-demo="interrupt" data-motion-active="false" data-motion-reduced={reduced}>
      <div className="il-copy">
        <span className="il-kicker">Interruptible WAAPI</span>
        <h2>Open, then change your mind</h2>
        <p>Repeated intent reverses the current playback instead of jumping to an endpoint.</p>
        <button type="button" onClick={toggle} aria-expanded={open}>
          {open ? "Close" : "Open"}
        </button>
      </div>
      <div ref={panel} className="il-interrupt-panel" aria-hidden={!open}>
        <span>Animation can be interrupted at any point.</span>
      </div>
    </section>
  );
}

function ReducedDemo() {
  const reduced = useReducedMotion();
  const cleanup = useCleanupRegistry();
  const node = useRef<HTMLOutputElement>(null);
  const play = () => {
    const current = node.current;
    if (!current) return;
    const surface = motionSurface(current);
    surface?.setAttribute("data-motion-active", "true");
    cancelAnimations(current);
    if (reduced) {
      current.style.opacity = "1";
      current.style.removeProperty("transform");
      surface?.setAttribute("data-motion-active", "false");
      return;
    }
    const animation = current.animate(
      [
        { opacity: 0, transform: "translateX(-24px)" },
        { opacity: 1, transform: "none" },
      ],
      { duration: 420, easing: "cubic-bezier(.2,.8,.2,1)" },
    );
    const stop = () => {
      animation.cancel();
      surface?.setAttribute("data-motion-active", "false");
    };
    const remove = cleanup.add(stop);
    void animation.finished.then(remove, remove);
  };
  return (
    <section className="il-card" data-motion-demo="reduced" data-motion-active="false" data-motion-reduced={reduced}>
      <div className="il-copy">
        <span className="il-kicker">Reduce motion</span>
        <h2>Same hierarchy, less travel</h2>
        <p>
          Live OS preference and <code>data-cmux-motion=reduce</code> keep focus and opacity while removing spatial
          motion.
        </p>
        <button type="button" onClick={play}>
          Replay
        </button>
      </div>
      <output ref={node} className="il-reduced-status">
        {reduced ? "Reduced path" : "Full motion path"}
      </output>
    </section>
  );
}

export function InteractionLabStage({ kind }: StageProps) {
  if (kind === "hierarchy") return <HierarchyDemo />;
  if (kind === "list") return <ListDemo />;
  if (kind === "gesture") return <GestureDemo />;
  if (kind === "interrupt") return <InterruptDemo />;
  return <ReducedDemo />;
}

const replay: Play = async (ctx) => {
  const demo = ctx.document.querySelector<HTMLElement>("[data-motion-demo]");
  if (!demo) return;
  if (demo.dataset.motionDemo === "gesture") {
    const target = { selector: '[data-motion-demo="gesture"] button' } as const;
    await ctx.pointer.down(target);
    await ctx.pointer.move(target);
    await ctx.pointer.up(target);
    await ctx.waitFor(() => demo.dataset.motionActive === "false", { capMs: 2_000 });
    return;
  }
  await ctx.click({ selector: "[data-motion-demo] button" });
  await ctx.waitFor(() => (demo.getAnimations?.() ?? []).length === 0, { capMs: 2_000 });
};

export default componentEntry<StageProps>({
  id: "motion.interaction-lab",
  title: "Interaction lab",
  area: "Motion",
  experimental: true,
  height: 520,
  widths: { narrow: 640, normal: 820, wide: 1040 },
  // Gallery-only stage; anchor coverage to the motion component family so the entry remains
  // discoverable by the gallery coverage test (gallery files themselves are intentionally skipped).
  covers: ["motion/SyncTitle.tsx#SyncTitle"],
  load: async () => InteractionLabStage,
  styles: () => import("./interactionLab.gallery.css"),
  variants: {
    "parent-child-shared-element": { props: { kind: "hierarchy" }, play: replay },
    "list-flip-stagger": { props: { kind: "list" }, play: replay },
    "gesture-spring": { props: { kind: "gesture" }, play: replay },
    "interruptible-waapi": { props: { kind: "interrupt" }, play: replay },
    "reduce-motion": { props: { kind: "reduced" }, play: replay },
  },
});
