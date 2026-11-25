// DIAGNOSTIC ONLY (lane/typing-forced-layout-split, never merged): splits a typed key's in-task time
// (goal typing-latency) into the editor's flush, dispatch, updateState, each plugin view's update,
// ProseMirror's scrollToSelection and every layout read, as sums per key on the key's TypingSample.
// Alternate keys run arm "noscroll" (scrollToSelection skipped) so both arms see the same host state.
import type { EditorView } from "@milkdown/kit/prose/view";

type Split = Record<string, number | string[] | string>;
let cur: Split | undefined;
let keyIndex = 0;
const now = () => performance.now();

function add(name: string, ms: number) {
  if (!cur) return;
  cur[name] = ((cur[name] as number | undefined) ?? 0) + ms;
  cur[`${name}#`] = ((cur[`${name}#`] as number | undefined) ?? 0) + 1;
}

function mark(name: string, start: number) {
  if (cur && cur[name] === undefined) cur[name] = now() - start;
}

let depth = 0;
function timed<T>(name: string, run: () => T): T {
  if (!cur) return run();
  const begin = now();
  depth++;
  try {
    return run();
  } finally {
    depth--;
    add(name, now() - begin);
  }
}

let layoutDepth = 0;
function layoutRead<T>(name: string, run: () => T): T {
  if (!cur || layoutDepth > 0) return run();
  layoutDepth++;
  const begin = now();
  try {
    return run();
  } finally {
    layoutDepth--;
    const took = now() - begin;
    add("layout", took);
    add(`layout:${name}`, took);
    if (took >= 1) {
      const stacks = (cur.stacks as string[] | undefined) ?? (cur.stacks = []);
      if (stacks.length < 3)
        stacks.push(
          `${name} ${took.toFixed(1)}ms ` +
            (new Error().stack ?? "")
              .split("\n")
              .slice(2, 9)
              .map((line) => line.trim().replace(/https?:\/\/[^ )]*\//g, ""))
              .join(" < "),
        );
    }
  }
}

// Per-listener marks: every keydown, keypress, beforeinput and input listener the page adds is wrapped, so a key's
// split holds `L:<type> <target> <site>` (the listener's own time) and `M:...` (to a microtask queued after it: what
// it scheduled, such as React's sync render, which runs in the microtask checkpoint after the listener).
const rawAdd = EventTarget.prototype.addEventListener;
const rawRemove = EventTarget.prototype.removeEventListener;
const SPLIT_TYPES = new Set(["keydown", "keypress", "keyup", "beforeinput", "input", "textInput", "selectionchange"]);
const wrappers = new WeakMap<object, Map<string, EventListener>>();
function describeTarget(target: unknown): string {
  if (target === window) return "window";
  if (typeof Document !== "undefined" && target instanceof Document) return "document";
  if (typeof Element !== "undefined" && target instanceof Element) {
    const cls = typeof target.className === "string" ? target.className.split(/\s+/).filter(Boolean).slice(0, 2).join(".") : "";
    return `${target.tagName.toLowerCase()}${target.id ? `#${target.id}` : ""}${cls ? `.${cls}` : ""}`;
  }
  return String(target);
}
function callSite(): string {
  const lines = (new Error().stack ?? "").split("\n").map((line) => line.trim());
  // Skip this file's frames: the first frame outside the wrapper is the caller of addEventListener.
  const outside = lines.filter((line) => line && !line.includes("callSite") && !line.includes("addEventListener"));
  return (outside[1] ?? outside[0] ?? "?").replace(/^.*?(@|at )/, "").replace(/https?:\/\/[^ )]*\//g, "");
}
function patchListeners() {
  if (typeof EventTarget === "undefined") return;
  EventTarget.prototype.addEventListener = function (
    this: EventTarget,
    type: string,
    listener: EventListenerOrEventListenerObject | null,
    options?: boolean | AddEventListenerOptions,
  ) {
    if (!listener || !SPLIT_TYPES.has(type)) return rawAdd.call(this, type, listener, options);
    const capture = typeof options === "boolean" ? options : Boolean(options?.capture);
    const key = `${type}:${capture}`;
    let byType = wrappers.get(listener);
    if (!byType) wrappers.set(listener, (byType = new Map()));
    let wrapper = byType.get(key);
    if (!wrapper) {
      const fn = typeof listener === "function" ? listener : listener.handleEvent;
      const src = String(fn).replace(/\s+/g, " ").slice(0, 90);
      const label = `${type}${capture ? "(c)" : ""} ${describeTarget(this)} ${fn?.name || "anon"} {${src}}`;
      wrapper = function (this: unknown, event: Event) {
        const split = cur;
        const begin = split ? now() : 0;
        try {
          return typeof listener === "function" ? listener.call(this, event) : listener.handleEvent(event);
        } finally {
          if (split && cur === split) {
            const took = now() - begin;
            add(`L:${label}`, took);
            queueMicrotask(() => {
              if (cur === split) add(`M:${label}`, now() - begin);
            });
          }
        }
      };
      byType.set(key, wrapper);
    }
    return rawAdd.call(this, type, wrapper, options);
  };
  EventTarget.prototype.removeEventListener = function (
    this: EventTarget,
    type: string,
    listener: EventListenerOrEventListenerObject | null,
    options?: boolean | EventListenerOptions,
  ) {
    if (listener && SPLIT_TYPES.has(type)) {
      const capture = typeof options === "boolean" ? options : Boolean(options?.capture);
      const wrapper = wrappers.get(listener)?.get(`${type}:${capture}`);
      if (wrapper) return rawRemove.call(this, type, wrapper, options);
    }
    return rawRemove.call(this, type, listener, options);
  };
}
patchListeners();

// MutationObserver callbacks run in the microtask checkpoint after the listener that saw the DOM change: each one's
// time, by where it was made (`MO:<site>`).
function patchMutationObservers() {
  if (typeof MutationObserver === "undefined") return;
  const Raw = MutationObserver;
  const Wrapped = function (this: unknown, callback: MutationCallback) {
    const label = `MO:${callSite()}`;
    return new Raw((records, observer) => {
      const split = cur;
      if (!split) return callback(records, observer);
      const begin = now();
      try {
        return callback(records, observer);
      } finally {
        if (cur === split) {
          add(label, now() - begin);
          queueMicrotask(() => {
            if (cur === split) add(`${label}+m`, now() - begin);
          });
        }
      }
    });
  } as unknown as typeof MutationObserver;
  Wrapped.prototype = Raw.prototype;
  (window as unknown as { MutationObserver: typeof MutationObserver }).MutationObserver = Wrapped;
}
if (typeof window !== "undefined") patchMutationObservers();

/** Times `run` into the key's split as `name` (a section of a listener or a view update). */
export function splitTimed<T>(name: string, run: () => T): T {
  return timed(name, run);
}

// The first keydown listener of the page (capture on window, added at module load): when JS first sees the key.
let firstKeydown = 0;
if (typeof window !== "undefined") rawAdd.call(window, "keydown", () => (firstKeydown = now()), { capture: true });

let patched = false;
function patchLayoutReads() {
  if (patched || typeof Element === "undefined") return;
  patched = true;
  const methods: [object, string][] = [
    [Element.prototype, "getBoundingClientRect"],
    [Element.prototype, "getClientRects"],
    [Range.prototype, "getBoundingClientRect"],
    [Range.prototype, "getClientRects"],
    [Element.prototype, "scrollIntoView"],
  ];
  for (const [proto, name] of methods) {
    const original = (proto as Record<string, (...args: unknown[]) => unknown>)[name];
    if (typeof original !== "function") continue;
    (proto as Record<string, unknown>)[name] = function (this: unknown, ...args: unknown[]) {
      return layoutRead(name, () => original.apply(this, args));
    };
  }
  const getters: [object, string][] = [
    [HTMLElement.prototype, "offsetHeight"],
    [HTMLElement.prototype, "offsetWidth"],
    [HTMLElement.prototype, "offsetTop"],
    [HTMLElement.prototype, "offsetLeft"],
    [Element.prototype, "clientHeight"],
    [Element.prototype, "clientWidth"],
    [Element.prototype, "scrollHeight"],
    [Element.prototype, "scrollWidth"],
    [Element.prototype, "scrollTop"],
  ];
  for (const [proto, name] of getters) {
    const descriptor = Object.getOwnPropertyDescriptor(proto, name);
    if (!descriptor?.get) continue;
    const get = descriptor.get;
    Object.defineProperty(proto, name, {
      ...descriptor,
      get(this: unknown) {
        return layoutRead(name, () => get.call(this));
      },
    });
  }
  const computed = window.getComputedStyle;
  window.getComputedStyle = function (this: Window, ...args: Parameters<typeof computed>) {
    return layoutRead("getComputedStyle", () => computed.apply(this, args));
  } as typeof computed;
}

/** The key's split starts: called from the perf key listener with the key's sample. */
export function splitKey(sample: Record<string, unknown>, start: number, target: EventTarget) {
  patchLayoutReads();
  const split: Split = {};
  cur = split;
  sample.split = split;
  sample.arm = "base";
  keyIndex++;
  split.arm = sample.arm as string;
  split.kdFirst = firstKeydown - start;
  split.kdSplitAt = now() - start;
  const win = typeof window === "undefined" ? undefined : window;
  if (!win) return;
  const once = (type: string, name: string, capture: boolean) =>
    rawAdd.call(win, type, () => mark(name, start), { capture, once: true });
  once("keydown", "kdEnd", false);
  once("keypress", "kp", true);
  once("beforeinput", "bi", true);
  once("input", "inStart", true);
  rawAdd.call(
    win,
    "input",
    () => {
      mark("inEnd", start);
      queueMicrotask(() => {
        mark("work", start);
        // What the edit left for the frame to lay out (after `work` is taken, so it is not in it).
        const begin = now();
        layoutDepth++;
        void document.documentElement.getBoundingClientRect();
        layoutDepth--;
        split.pendingLayout = now() - begin;
        cur = undefined;
      });
    },
    { capture: false, once: true },
  );
  void target;
}

const wrapped = new WeakSet<object>();
/** Wraps the editor view's own steps once (instance properties shadow the prototype's). */
export function instrumentView(view: EditorView) {
  const anyView = view as unknown as Record<string, unknown> & {
    domObserver: Record<string, unknown>;
    pluginViews: { update?: (...args: unknown[]) => void }[];
    directPlugins: { spec: { view?: unknown }; key: string }[];
  };
  if (wrapped.has(view)) return;
  wrapped.add(view);
  const wrap = (owner: Record<string, unknown>, name: string, label: string) => {
    const original = owner[name] as (...args: unknown[]) => unknown;
    if (typeof original !== "function") return;
    owner[name] = function (this: unknown, ...args: unknown[]) {
      return timed(label, () => original.apply(this, args));
    };
  };
  wrap(anyView.domObserver, "flush", "flush");
  wrap(anyView, "dispatch", "dispatch");
  wrap(anyView, "updateState", "updateState");
  const updatePluginViews = anyView.updatePluginViews as (...args: unknown[]) => unknown;
  anyView.updatePluginViews = function (this: unknown, ...args: unknown[]) {
    const names = [...(anyView.directPlugins ?? []), ...view.state.plugins]
      .filter((plugin) => plugin.spec.view)
      .map((plugin) => plugin.key);
    anyView.pluginViews.forEach((pluginView, index) => {
      if (!pluginView.update || wrapped.has(pluginView)) return;
      wrapped.add(pluginView);
      const update = pluginView.update;
      const label = `pv:${names[index] ?? index}`;
      pluginView.update = (...updateArgs: unknown[]) => timed(label, () => update.apply(pluginView, updateArgs));
    });
    return timed("pluginViews", () => updatePluginViews.apply(this, args));
  };
  const scrollToSelection = anyView.scrollToSelection as (...args: unknown[]) => unknown;
  anyView.scrollToSelection = function (this: unknown, ...args: unknown[]) {
    if (cur?.arm === "noscroll") {
      add("scrollSkipped", 0);
      return;
    }
    return timed("scrollToSelection", () => scrollToSelection.apply(this, args));
  };
}
