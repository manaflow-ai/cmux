// The facts hover card (src/agent-session/acpmux/chips/FactsHoverCard.tsx WithFacts) as a sighted
// person sees it: what the card shows when its trigger gets focus (it opens at once on focus, with
// no dwell), not the trigger's hidden description.
import { act, type ReactNode } from "react";
import type { Root } from "react-dom/client";
import { loadLazyChunks } from "../../src/lazyChunk";
import { settleReact } from "./domTeardown";

/** The label as drawn, excluding the hidden descriptions used by the facts card. */
export function visibleLabelText(element: Element): string {
  const label = element.cloneNode(true) as Element;
  for (const hidden of label.querySelectorAll("[hidden]")) hidden.remove();
  return label.textContent?.trim() ?? "";
}

/// Opens `element`'s facts card as keyboard focus does, reads what it shows, then closes it again.
/// "" when no card opens. The card's popup (Base UI, placed by floating-ui) reads a few window
/// globals: a page that installed none gets its own window's while the card is open, and keeps them
/// until the card's last placement has run.
export async function factsCardText(element: Element): Promise<string> {
  const view = element.ownerDocument.defaultView!;
  const scope = globalThis as Record<string, unknown>;
  const lent = Object.entries(popupGlobals(view)).filter(([key]) => !(key in scope));
  for (const [key, value] of lent) scope[key] = value;
  try {
    await act(async () => {
      element.dispatchEvent(new view.FocusEvent("focusin", { bubbles: true }));
      // A card asked for before its chunk is in opens when it arrives (src/lazyChunk.ts): a file
      // that loaded the card's trigger after its first test began has it fetched only now.
      await loadLazyChunks();
    });
    const card = element.ownerDocument.querySelector("[data-facts-card]");
    const text = card?.textContent ?? "";
    await act(async () => {
      element.dispatchEvent(new view.FocusEvent("focusout", { bubbles: true }));
    });
    await settleReact();
    // A placement already asked for resolves on a later turn.
    for (let turn = 0; turn < 3; turn += 1) await new Promise((resolve) => setTimeout(resolve, 0));
    return text;
  } finally {
    for (const [key] of lent) delete scope[key];
  }
}

/// What the card's popup reads from the window: its frames, its styles, its node classes and a size
/// observer.
function popupGlobals(view: Window): Record<string, unknown> {
  const visual = typeof view.requestAnimationFrame === "function";
  return {
    requestAnimationFrame: visual
      ? view.requestAnimationFrame.bind(view)
      : (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0),
    cancelAnimationFrame: visual ? view.cancelAnimationFrame.bind(view) : (handle: number) => clearTimeout(handle),
    getComputedStyle: view.getComputedStyle.bind(view),
    // floating-ui tells a DOM node by the page's own classes.
    Node: (view as unknown as { Node: unknown }).Node,
    Element: (view as unknown as { Element: unknown }).Element,
    HTMLElement: (view as unknown as { HTMLElement: unknown }).HTMLElement,
    ShadowRoot: (view as unknown as { ShadowRoot: unknown }).ShadowRoot,
    ResizeObserver:
      (view as unknown as { ResizeObserver?: unknown }).ResizeObserver ??
      class {
        observe() {}
        unobserve() {}
        disconnect() {}
      },
  };
}

/// The text of the hidden element that describes `element` (`aria-describedby`), "" when none.
export function describedText(element: Element): string {
  const ids = element.getAttribute("aria-describedby")?.split(/\s+/) ?? [];
  return ids
    .map((id) => element.ownerDocument.getElementById(id)?.textContent ?? "")
    .join(" ")
    .trim();
}

/// A JSDOM page with `node` rendered, for a test file that has no DOM of its own; `close` unmounts
/// it, lets React finish and puts the globals back.
export async function renderInDom(node: ReactNode): Promise<{ container: HTMLElement; close(): Promise<void> }> {
  // react-dom loads after the window is in place (it reads it once, as it loads), as test files that
  // build their own page do; this module itself never loads it.
  const { JSDOM } = await import("jsdom");
  const dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  const scope = globalThis as Record<string, unknown>;
  const keys = [
    "window",
    "document",
    "Node",
    "HTMLElement",
    "Element",
    "FocusEvent",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ];
  const saved = keys.map((key) => [key, scope[key]] as const);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    FocusEvent: dom.window.FocusEvent,
    // A page's effects ask for frames (GitHubPage tells the host once its first frame is drawn).
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const { createRoot } = await import("react-dom/client");
  const container = dom.window.document.getElementById("root")!;
  let root: Root | undefined;
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return {
    container,
    async close() {
      await act(async () => root?.unmount());
      await settleReact();
      dom.window.close();
      for (const [key, value] of saved) {
        if (value === undefined) delete scope[key];
        else scope[key] = value;
      }
    },
  };
}
