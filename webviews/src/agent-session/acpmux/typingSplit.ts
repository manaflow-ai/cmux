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
  sample.arm = keyIndex++ % 2 === 0 ? "base" : "noscroll";
  split.arm = sample.arm as string;
  const win = typeof window === "undefined" ? undefined : window;
  if (!win) return;
  const once = (type: string, name: string, capture: boolean) =>
    win.addEventListener(type, () => mark(name, start), { capture, once: true });
  once("keydown", "kdEnd", false);
  once("keypress", "kp", true);
  once("beforeinput", "bi", true);
  once("input", "inStart", true);
  win.addEventListener(
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
