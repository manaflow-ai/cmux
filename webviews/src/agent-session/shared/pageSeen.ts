// Whether anyone sees this page, as the native host knows it. Leo, 2026-11-18: "Why should non
// visible thing even affect the renderer thread anyways?"
//
// The document's own `visibilityState` says "visible" for a page nobody can see: the New Tab spare
// waits painted in the key window, 100,000 pt outside its content (PageOffscreenParking.swift), and
// an adopted page's engine view stays shown while a pane holds it away. Every page of the app shares
// one renderer, so such a page's work took the frames of the chat being scrolled.
//
// The host calls `window.cmuxPageSeen(false)` once the page painted and nobody sees it, and
// `window.cmuxPageSeen(true)` in the same turn it shows again (AgentPaneShownPushes.swift
// `AgentPageSeenSignal`). Unseen, `document.visibilityState` reads "hidden" and `document.hidden`
// true, and a `visibilitychange` fires, so every reader in the page (the acpmux client's watch and
// draws, the page clocks and loops, the reveal settle) holds its work as it does for a hidden tab,
// and catches up on the change back. A page starts seen; the host sends false after each load when
// it is not.

type Seen = { seen: boolean };

const states = new WeakMap<Document, Seen>();

/// Installs the host's seen switch on `win` (once per document). Returns the switch, for tests.
export function installPageSeen(win: Window | undefined = typeof window === "undefined" ? undefined : window) {
  const doc = win?.document;
  if (!win || !doc) return undefined;
  const existing = (win as { cmuxPageSeen?: (seen: boolean) => void }).cmuxPageSeen;
  if (existing && states.has(doc)) return existing;
  const state: Seen = { seen: true };
  states.set(doc, state);
  const proto = Object.getPrototypeOf(doc) as object;
  const visibility = lookupGetter(proto, "visibilityState");
  const hidden = lookupGetter(proto, "hidden");
  // Own accessors over the prototype's: the engine's value while the page is seen, hidden while not.
  Object.defineProperty(doc, "visibilityState", {
    configurable: true,
    get: () => (state.seen ? (visibility?.call(doc) ?? "visible") : "hidden"),
  });
  Object.defineProperty(doc, "hidden", {
    configurable: true,
    get: () => (state.seen ? Boolean(hidden?.call(doc)) : true),
  });
  const set = (seen: boolean) => {
    if (typeof seen !== "boolean" || seen === state.seen) return;
    const before = doc.visibilityState;
    state.seen = seen;
    // Only a change the page can read: an unseen page in a tab already hidden reads the same.
    if (doc.visibilityState !== before) doc.dispatchEvent(new (win.Event ?? Event)("visibilitychange"));
  };
  (win as { cmuxPageSeen?: (seen: boolean) => void }).cmuxPageSeen = set;
  return set;
}

/// Whether the host says someone sees `doc` (true where no host said otherwise).
export function hostSeesPage(doc: Document | undefined = typeof document === "undefined" ? undefined : document) {
  return doc ? (states.get(doc)?.seen ?? true) : true;
}

function lookupGetter(proto: object | null, name: string): (() => unknown) | undefined {
  for (let at = proto; at; at = Object.getPrototypeOf(at) as object | null) {
    const descriptor = Object.getOwnPropertyDescriptor(at, name);
    if (descriptor?.get) return descriptor.get as () => unknown;
  }
  return undefined;
}
