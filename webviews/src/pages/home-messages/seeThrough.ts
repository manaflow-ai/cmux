// The see-through Chief (ChiefPanelStyle.seeThrough and .seeThroughBar, 0d682b6e and 94888846): while the
// floating Chief panel shows this page in a see-through style, the page draws no background of its own, so
// the workspace shows between the bubbles, as the native transcript's `clearsBackground` did. Bubbles, text
// and the message box still draw; nothing gets a halo (94888846 took it off: it blurred every bubble).
//
// The plates behind the panel's bar and this page's header, and under the message box, are the panel's
// (ChiefPanelView's veils, native, behind the web view): a page backdrop samples nothing behind the web
// view, so a page-drawn glass shows nothing there (94888846's capture). The page clears its own header and
// compose fills so those veils are the one plate, and it tells the host how tall its header is, as
// HomeHostView.chiefHeaderHeight did, so the header veil ends under the header and not over the chat.
//
//   seeThrough (stream)  {showsThrough}: the host's switch (HomeMessagesSeeThrough.swift)
//   seeThrough.header {height}: the header's bottom from the page's top, CSS px, while see-through
import { useEffect } from "react";
import type { PageClient } from "../shared/pageClient";
import { useHostStream } from "./detail/detailHost";

export const SeeThroughOps = {
  stream: "cmux.home.messages.seeThrough",
  header: "cmux.home.messages.seeThrough.header",
} as const;

/** The root attribute styles.css keys the see-through style on. */
export const SEE_THROUGH_ATTRIBUTE = "data-home-see-through";

/** The stream's switch; anything but `{showsThrough: true}` keeps the page's background. */
export function parseSeeThrough(event: unknown): boolean {
  return (
    !!event &&
    typeof event === "object" &&
    !Array.isArray(event) &&
    (event as Record<string, unknown>).showsThrough === true
  );
}

/** Turns the see-through style on `root` (the document element) on or off. */
export function applySeeThrough(root: HTMLElement, on: boolean): void {
  if (on) root.setAttribute(SEE_THROUGH_ATTRIBUTE, "");
  else root.removeAttribute(SEE_THROUGH_ATTRIBUTE);
}

// ---------- The header ----------

type HeaderListener = (element: HTMLElement | null) => void;
/** The mounted headers, newest last: the newest is the shown one. */
const headers: HTMLElement[] = [];
const headerListeners = new Set<HeaderListener>();
const shownHeader = (): HTMLElement | null => headers.at(-1) ?? null;

/** The transcript header's ref (TranscriptHeader): the newest mounted header is the one whose height is
 * reported. Returns the ref's cleanup (React 19), which takes that header back out. */
export function attachHeader(element: HTMLElement | null): (() => void) | undefined {
  if (!element) return undefined;
  headers.push(element);
  for (const listener of headerListeners) listener(shownHeader());
  return () => {
    const index = headers.lastIndexOf(element);
    if (index < 0) return;
    const wasShown = index === headers.length - 1;
    headers.splice(index, 1);
    if (wasShown) for (const listener of headerListeners) listener(shownHeader());
  };
}

/** The header's height to report: its bottom from the page's top, whole CSS px; 0 without a header. */
export function headerHeight(element: HTMLElement | null): number {
  if (!element) return 0;
  return Math.max(0, Math.ceil(element.getBoundingClientRect().bottom));
}

/** Calls `report` with the shown header's height now and on each change (a resize, another header); each
 * height once. Returns the stop. */
export function followHeaderHeight(report: (height: number) => void): () => void {
  let last: number | undefined;
  let observer: ResizeObserver | undefined;
  const send = (element: HTMLElement | null) => {
    const height = headerHeight(element);
    if (height === last) return;
    last = height;
    report(height);
  };
  const watch: HeaderListener = (element) => {
    observer?.disconnect();
    observer = undefined;
    if (element && typeof ResizeObserver !== "undefined") {
      observer = new ResizeObserver(() => send(element));
      observer.observe(element);
    }
    send(element);
  };
  headerListeners.add(watch);
  watch(shownHeader());
  return () => {
    headerListeners.delete(watch);
    observer?.disconnect();
  };
}

/** The host's see-through switch for this page: sets the style on the document and, while it is on,
 * reports the header's height. False without a host (a browser, the gallery). */
export function useSeeThrough(host: PageClient | null): boolean {
  const on = useHostStream(host, SeeThroughOps.stream, parseSeeThrough, false);
  useEffect(() => {
    const root = document.documentElement;
    applySeeThrough(root, on);
    return () => applySeeThrough(root, false);
  }, [on]);
  useEffect(() => {
    if (!host || !on) return;
    return followHeaderHeight((height) => void host.call(SeeThroughOps.header, { height }).catch(() => undefined));
  }, [host, on]);
  return on;
}
