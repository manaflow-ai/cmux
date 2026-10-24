import { HoverIntent } from "../../../ui/hoverIntent";

// One policy/visibility observer per document, shared by hovered players only.
// No transcript scan, computed style read or idle listener per mounted thumbnail.
const pages = new WeakMap<Document, { listeners: Set<() => void>; dispose(): void }>();

function watchPage(doc: Document, stop: () => void): () => void {
  let page = pages.get(doc);
  if (!page) {
    const listeners = new Set<() => void>();
    const cancel = () => {
      for (const listener of listeners) listener();
    };
    const view = doc.defaultView;
    const media = view?.matchMedia?.("(prefers-reduced-motion: reduce)");
    const observer = view ? new view.MutationObserver(cancel) : undefined;
    observer?.observe(doc.documentElement, {
      attributes: true,
      attributeFilter: ["data-agent-motion", "data-cmux-motion"],
    });
    doc.addEventListener("scroll", cancel, true);
    doc.addEventListener("visibilitychange", cancel);
    view?.addEventListener("pagehide", cancel);
    media?.addEventListener("change", cancel);
    page = {
      listeners,
      dispose() {
        observer?.disconnect();
        doc.removeEventListener("scroll", cancel, true);
        doc.removeEventListener("visibilitychange", cancel);
        view?.removeEventListener("pagehide", cancel);
        media?.removeEventListener("change", cancel);
      },
    };
    pages.set(doc, page);
  }
  page.listeners.add(stop);
  return () => {
    page.listeners.delete(stop);
    if (page.listeners.size === 0) {
      page.dispose();
      pages.delete(doc);
    }
  };
}

function allowed(video: HTMLVideoElement): boolean {
  const doc = video.ownerDocument;
  return (
    video.isConnected &&
    !doc.hidden &&
    doc.documentElement.dataset.agentMotion !== "off" &&
    doc.documentElement.dataset.cmuxMotion !== "off" &&
    doc.documentElement.dataset.cmuxMotion !== "reduced" &&
    !doc.defaultView?.matchMedia?.("(prefers-reduced-motion: reduce)").matches
  );
}

/** One bounded hover timer. Explicit playback owns the element once it is unmuted. */
export function mediaHover(video: HTMLVideoElement) {
  let unwatch: (() => void) | undefined;
  const stop = () => {
    intent.dismiss();
    if (video.muted) video.pause();
    unwatch?.();
    unwatch = undefined;
  };
  const intent = new HoverIntent({
    show() {
      if (!allowed(video) || !video.muted) {
        stop();
        return;
      }
      void video
        .play()
        ?.then(() => {
          // A late play promise cannot revive a dismissed preview or pause a click.
          if (intent.shown !== video && video.muted) video.pause();
        })
        .catch(() => {});
    },
    hide() {
      if (video.muted) video.pause();
    },
  });
  return {
    enter() {
      if (!allowed(video) || !video.muted) return;
      unwatch ??= watchPage(video.ownerDocument, stop);
      intent.hover(video);
    },
    stop,
  };
}
