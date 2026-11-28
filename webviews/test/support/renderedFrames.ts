import type { Page } from "playwright";

declare global {
  interface Window {
    /** Capture read-only geometry during rendering. The consumer receives the final snapshot
     * from that render, never a live DOM read from a later task. */
    cmuxFrameSnapshots: <T>(
      capture: (frame: number) => T,
      consume: (snapshot: T, frame: number) => boolean | void,
      drive?: (frame: number) => void,
    ) => () => void;
  }
}

function defineRenderedFrames() {
  if (typeof window.cmuxFrameSnapshots === "function") return;
  const NativeObserver = window.ResizeObserver;
  const targets = new Set<Set<Element>>();
  const dirty = new Set<() => void>();
  // Install before application code creates observers. A callback may change geometry after our
  // sentinel's callback, or in a microtask; another deeper delivery captures those changes.
  window.ResizeObserver = class extends NativeObserver {
    private readonly nodes = new Set<Element>();
    constructor(callback: ResizeObserverCallback) {
      super(function (this: ResizeObserver, entries, observer) {
        try {
          callback.call(this, entries, observer);
        } finally {
          for (const mark of dirty) mark();
        }
      });
    }
    override observe(target: Element, options?: ResizeObserverOptions) {
      super.observe(target, options);
      this.nodes.add(target);
      targets.add(this.nodes);
      for (const mark of dirty) mark();
    }
    override unobserve(target: Element) {
      super.unobserve(target);
      this.nodes.delete(target);
      if (!this.nodes.size) targets.delete(this.nodes);
    }
    override disconnect() {
      super.disconnect();
      this.nodes.clear();
      targets.delete(this.nodes);
    }
  };
  const depth = (node: Node): number => {
    let count = 0;
    let at: Node | null = node;
    while (at) {
      count++;
      at =
        at instanceof Element && at.assignedSlot ? at.assignedSlot : at instanceof ShadowRoot ? at.host : at.parentNode;
    }
    return count;
  };
  window.cmuxFrameSnapshots = (capture, consume, drive) => {
    const root = document.createElement("div");
    root.style.cssText =
      "position:fixed;left:-10000px;top:0;width:1px;height:1px;contain:strict;visibility:hidden;pointer-events:none";
    const sentinel = document.createElement("div");
    sentinel.style.cssText = "width:1px;height:1px";
    root.append(sentinel);
    document.documentElement.append(root);
    let stopped = false;
    let frame = -1;
    let serial = 1;
    let snapshot: { frame: number; value: ReturnType<typeof capture> } | undefined;
    const deliver = () => {
      if (!snapshot || stopped) return;
      const saved = snapshot;
      snapshot = undefined;
      if (consume(saved.value, saved.frame) === false) stop();
    };
    const mark = () => {
      if (stopped) return;
      let deepest = 0;
      for (const nodes of targets)
        for (const node of nodes) if (node.isConnected) deepest = Math.max(deepest, depth(node));
      // ResizeObserver's depth bound increases each round. Our target stays deeper than every
      // application target, so marking it never changes which application entries may deliver.
      // Recompute after callbacks as well as RAF: a callback may observe or reparent a target.
      while (depth(sentinel) <= deepest) {
        const parent = document.createElement("div");
        parent.style.cssText = "width:1px;height:1px";
        sentinel.replaceWith(parent);
        parent.append(sentinel);
      }
      // Two producer callbacks must not toggle back to the last delivered size.
      sentinel.style.width = `${++serial}px`;
    };
    const observer = new NativeObserver(() => {
      if (!stopped && frame >= 0) snapshot = { frame, value: capture(frame) };
    });
    const channel = new MessageChannel();
    channel.port1.onmessage = deliver;
    let requested = 0;
    const stop = () => {
      if (stopped) return;
      deliver();
      stopped = true;
      cancelAnimationFrame(requested);
      dirty.delete(mark);
      observer.disconnect();
      channel.port1.close();
      channel.port2.close();
      root.remove();
    };
    const tick = (time: number) => {
      // A busy browser can begin another render before the posted task. Consume the previous
      // immutable snapshot before replacing it, preserving even a one-frame collision.
      deliver();
      if (stopped) return;
      frame = time;
      drive?.(time);
      mark();
      channel.port2.postMessage(null);
      // raf-read: schedules capture in the final ResizeObserver round; no geometry is read here.
      requested = requestAnimationFrame(tick);
    };
    dirty.add(mark);
    observer.observe(sentinel);
    requested = requestAnimationFrame(tick);
    return stop;
  };
}

/** Call before navigation, so all application ResizeObservers participate in the checkpoint. */
export async function installRenderedFrames(page: Page) {
  await page.addInitScript(defineRenderedFrames);
  await page.evaluate(defineRenderedFrames);
}
