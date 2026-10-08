// Runs a variant's play steps in the stage frame and measures each one (play.ts has the rules).
import {
  describeTarget,
  judgeStep,
  overall,
  rectDelta,
  resolveTarget,
  type Play,
  type PlayAction,
  type PlayChecks,
  type PlayContext,
  type PlayReport,
  type PlayTarget,
  type Rect,
  type Shift,
  type StepReport,
} from "../play";

/** What the matrix runner installs for trusted input (Playwright's mouse and keyboard). */
type InputDriver = (action: {
  kind: "click" | "hover" | "down" | "move" | "up" | "type" | "press";
  x?: number;
  y?: number;
  text?: string;
}) => Promise<void>;

declare global {
  interface Window {
    cmuxGalleryInput?: InputDriver;
    cmuxGalleryPlayReport?: PlayReport;
  }
}

const rectOf = (element: Element | null): Rect | null => {
  if (!element) return null;
  const rect = element.getBoundingClientRect();
  return { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
};

/** The element's center in the top page's coordinates (through same-origin parent frames). */
function pageCenter(element: Element): { x: number; y: number } {
  const rect = element.getBoundingClientRect();
  let x = rect.x + rect.width / 2;
  let y = rect.y + rect.height / 2;
  for (let frame: Window = window; frame !== frame.parent && frame.frameElement; frame = frame.parent) {
    const offset = frame.frameElement.getBoundingClientRect();
    x += offset.x;
    y += offset.y;
  }
  return { x, y };
}

const nextFrame = () => new Promise<number>((resolve) => requestAnimationFrame(resolve));

let actionSequence = 0;

/** Two frames, then every running animation and transition finished: the step has settled. */
async function settle(): Promise<void> {
  await nextFrame();
  await nextFrame();
  const running = document.getAnimations?.() ?? [];
  await Promise.race([
    Promise.allSettled(running.map((animation) => animation.finished)),
    // A looping animation (a spinner) never finishes: it does not hold the step.
    nextFrame().then(nextFrame).then(nextFrame),
  ]);
}

function synthetic(element: Element, kind: string): void {
  const { x, y } = (() => {
    const rect = element.getBoundingClientRect();
    return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
  })();
  const init = {
    bubbles: true,
    cancelable: true,
    composed: true,
    clientX: x,
    clientY: y,
    button: 0,
    pointerId: 1,
    isPrimary: true,
  };
  const fire = (type: string) =>
    element.dispatchEvent(type.startsWith("pointer") ? new PointerEvent(type, init) : new MouseEvent(type, init));
  if (kind === "hover")
    ["pointerover", "pointerenter", "mouseover", "mouseenter", "pointermove", "mousemove"].forEach(fire);
  if (kind === "down" || kind === "click") ["pointerdown", "mousedown"].forEach(fire);
  if (kind === "move") ["pointermove", "mousemove"].forEach(fire);
  if (kind === "up" || kind === "click") ["pointerup", "mouseup"].forEach(fire);
  if (kind === "click") fire("click");
}

function syntheticKey(key: string): void {
  const parts = key.split("+");
  const name = parts.pop()!;
  const modifiers = {
    metaKey: parts.includes("Meta"),
    ctrlKey: parts.includes("Control"),
    altKey: parts.includes("Alt"),
    shiftKey: parts.includes("Shift"),
  };
  // The focused element, inside open shadow roots too (a web component's focused row).
  let target: Element = document.activeElement ?? document.body;
  while (target.shadowRoot?.activeElement) target = target.shadowRoot.activeElement;
  const keydown = new KeyboardEvent("keydown", {
    key: name,
    bubbles: true,
    cancelable: true,
    composed: true,
    ...modifiers,
  });
  target.dispatchEvent(keydown);
  target.dispatchEvent(new KeyboardEvent("keyup", { key: name, bubbles: true, cancelable: true, composed: true, ...modifiers }));
  // KeyboardEvent dispatch does not run the browser's default button activation.
  // Reproduce it for the shell runner so a native button behaves like the trusted
  // Playwright path used by the matrix runner.
  if (!keydown.defaultPrevented && (name === "Enter" || name === " ") && target instanceof HTMLElement) {
    const role = target.getAttribute("role");
    if (target instanceof HTMLButtonElement || role === "button") target.click();
  }
}

/** Measures one step: anchors before and after, layout shifts and frame times during it. */
async function measured(
  step: string,
  action: PlayAction,
  targeted: Element | null,
  anchors: { label: string; target: PlayTarget }[],
  checks: PlayChecks,
  run: () => Promise<void>,
): Promise<StepReport> {
  const resolve = () => anchors.map(({ label, target }) => ({ label, element: resolveTarget(document, target) }));
  const before = resolve().map(({ label, element }) => ({ label, element, rect: rectOf(element) }));
  const shifts: Shift[] = [];
  const longFrames: number[] = [];
  const loafSupported = PerformanceObserver.supportedEntryTypes?.includes("long-animation-frame") ?? false;
  const observers: PerformanceObserver[] = [];
  if (PerformanceObserver.supportedEntryTypes?.includes("layout-shift")) {
    const observer = new PerformanceObserver((list) => {
      for (const entry of list.getEntries() as (PerformanceEntry & {
        value: number;
        hadRecentInput: boolean;
        sources?: { node?: Node }[];
      })[])
        shifts.push({
          value: entry.value,
          sources: (entry.sources ?? []).map((source) =>
            source.node instanceof Element
              ? `${source.node.tagName.toLowerCase()}${source.node.className ? `.${String(source.node.className).split(" ")[0]}` : ""}`
              : "#text",
          ),
        });
    });
    observer.observe({ type: "layout-shift", buffered: false });
    observers.push(observer);
  }
  let rafRunning = !loafSupported;
  if (loafSupported) {
    const observer = new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) if (entry.duration > 16.7) longFrames.push(entry.duration);
    });
    observer.observe({ type: "long-animation-frame", buffered: false });
    observers.push(observer);
  } else {
    void (async () => {
      let last = await nextFrame();
      while (rafRunning) {
        const now = await nextFrame();
        if (now - last > 16.7) longFrames.push(now - last);
        last = now;
      }
    })();
  }
  const mark = `cmux-gallery-action-${++actionSequence}`;
  const startMark = `${mark}-start`;
  const endMark = `${mark}-settled`;
  performance.mark(startMark);
  await run();
  await settle();
  performance.mark(endMark);
  const timing = performance.measure(mark, startMark, endMark);
  const settleMs = Math.round(timing.duration * 10) / 10;
  performance.clearMarks(startMark);
  performance.clearMarks(endMark);
  performance.clearMeasures(mark);
  rafRunning = false;
  for (const observer of observers) {
    observer.takeRecords();
    observer.disconnect();
  }
  const anchorMoves = before
    .filter(
      ({ element }) =>
        !(targeted && element && (element === targeted || element.contains(targeted) || targeted.contains(element))),
    )
    .map(({ label, element, rect }) => {
      const after = rectOf(
        element?.isConnected
          ? element
          : resolveTarget(document, anchors.find((anchor) => anchor.label === label)!.target),
      );
      return { anchor: label, before: rect, after, delta: rectDelta(rect, after) };
    })
    .filter((move) => move.delta > 0);
  const layoutShift = shifts.reduce((sum, shift) => sum + shift.value, 0);
  const result = {
    step,
    action,
    settleMs,
    anchorMoves,
    layoutShift,
    shifts,
    longFrames,
    frameSource: loafSupported ? ("long-animation-frame" as const) : ("raf" as const),
  };
  return { ...result, ...judgeStep(result, checks) };
}

export async function runPlay(
  play: Play,
  options: { anchors?: PlayTarget[]; checks?: PlayChecks },
): Promise<PlayReport> {
  const anchors = (options.anchors ?? []).map((target) => ({ label: describeTarget(target), target }));
  const checks = options.checks ?? {};
  const steps: StepReport[] = [];
  const find = (target: PlayTarget) => {
    const element = resolveTarget(document, target);
    if (!element) throw new Error(`play: no element for ${describeTarget(target)}`);
    return element;
  };
  const input = async (kind: "click" | "hover" | "down" | "move" | "up", target: PlayTarget) => {
    const element = find(target);
    const action: PlayAction = kind === "click" ? "click" : kind === "hover" ? "hover" : "press-drag";
    await measured(`${kind} ${describeTarget(target)}`, action, element, anchors, checks, async () => {
      if (window.top?.cmuxGalleryInput) await window.top.cmuxGalleryInput({ kind, ...pageCenter(element) });
      else synthetic(element, kind);
    }).then((step) => steps.push(step));
  };
  const gesture = async (
    name: string,
    action: PlayAction,
    target: Element | null,
    run: () => void | Promise<void>,
  ): Promise<void> => {
    steps.push(
      await measured(name, action, target, anchors, checks, async () => {
        await run();
      }),
    );
  };
  const ctx: PlayContext = {
    document,
    find,
    click: (target) => input("click", target),
    hover: (target) => input("hover", target),
    focus: async (target) => {
      const element = find(target) as HTMLElement;
      steps.push(
        await measured(`focus ${describeTarget(target)}`, "focus", element, anchors, checks, async () =>
          element.focus(),
        ),
      );
    },
    scroll: async (target, position) => {
      const element = find(target) as HTMLElement;
      await gesture(`scroll ${describeTarget(target)} to ${String(position)}`, "scroll", element, () => {
        const top =
          typeof position === "number"
            ? position
            : position === "bottom"
              ? Math.max(0, element.scrollHeight - element.clientHeight)
              : 0;
        element.scrollTop = top;
        element.dispatchEvent(new Event("scroll", { bubbles: false }));
      });
    },
    selectText: async (target) => {
      const element = find(target);
      await gesture(`select text in ${describeTarget(target)}`, "select", element, () => {
        const selection = document.getSelection();
        if (!selection) return;
        const range = document.createRange();
        range.selectNodeContents(element);
        selection.removeAllRanges();
        selection.addRange(range);
      });
    },
    type: async (text, target) => {
      const element = target ? (find(target) as HTMLElement) : (document.activeElement as HTMLElement | null);
      steps.push(
        await measured(`type ${JSON.stringify(text.slice(0, 20))}`, "type", element, anchors, checks, async () => {
          element?.focus();
          if (window.top?.cmuxGalleryInput) await window.top.cmuxGalleryInput({ kind: "type", text });
          // eslint-disable-next-line @typescript-eslint/no-deprecated -- insertText is the one DOM path that edits inputs, textareas and contenteditable as typing does.
          else for (const character of text) document.execCommand("insertText", false, character);
        }),
      );
    },
    press: async (key) => {
      steps.push(
        await measured(`press ${key}`, "key", document.activeElement, anchors, checks, async () => {
          if (window.top?.cmuxGalleryInput) await window.top.cmuxGalleryInput({ kind: "press", text: key });
          else syntheticKey(key);
        }),
      );
    },
    pointer: {
      down: (target) => input("down", target),
      move: (target) => input("move", target),
      up: (target) => input("up", target),
    },
    waitFor: (condition, { capMs = 5000 } = {}) =>
      new Promise<void>((resolve, reject) => {
        const check = () => {
          let held: unknown;
          try {
            held = condition();
          } catch {
            held = false;
          }
          if (!held) return false;
          observer.disconnect();
          clearTimeout(cap);
          resolve();
          return true;
        };
        const observer = new MutationObserver(() => void check());
        // The cap fails a wait that never comes true; it is not how the wait resolves.
        const cap = window.setTimeout(() => {
          observer.disconnect();
          reject(new Error(`play: waitFor did not hold within ${capMs} ms`));
        }, capMs);
        observer.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
        document.addEventListener("animationend", check, { once: true });
        document.addEventListener("transitionend", check, { once: true });
        if (!check()) void nextFrame().then(check);
      }),
  };
  try {
    await play(ctx);
    return { status: overall(steps), steps };
  } catch (error) {
    return { status: "fail", steps, error: error instanceof Error ? error.message : String(error) };
  }
}
