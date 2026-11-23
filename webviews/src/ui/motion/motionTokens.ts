// The page's motion tokens (`--agent-motion-send`, `--agent-motion-move`, `--agent-motion-in`) as a node
// resolves them, read once and kept until something that sets them changes. A read of a custom property
// through getComputedStyle recalculates the whole page's style when it runs after a commit's writes: in a
// send's commit (the Enter's task) one such read cost 13.5 ms of a 99 ms task at 2,001 rows, and every
// later reader paid again after the next writes (cmuxterm-hq docs/findings/2026-11-23-agent-pane-send-paint.md).
//
// The tokens are constant per page and theme: the host's theme writes them inline on the root
// (agent-session/shared/theme.ts), the stylesheets in the head define the rest, and two attributes over a
// node change them for it (`data-chat-motion="minimal"`, frameBudget.ts; `data-send-entrance`, SEND-SLIM in
// composerStates.css). So a read is kept per node and name, keyed by those two attributes (read from the
// DOM, no style flush), and every kept read goes when the root's attributes, the head's sheets or the
// Reduce Motion setting change. `warmMotionTokens` reads a node's tokens at a quiet moment (an idle
// callback, after a frame), so the first send after a load or a theme change reads none either.

type Kept = { epoch: number; key: string; value: string };

const epochs = new WeakMap<Document, { epoch: number }>();
const kept = new WeakMap<Element, Map<string, Kept>>();
const warm = new Map<Element, readonly string[]>();
let rewarm: (() => void) | undefined;

/// The document's token epoch, watched from its first read: bumped when its root's attributes (the host's
/// inline tokens, `data-agent-motion`, a page-wide minimal motion), its head's sheets (a theme.css, a lazily
/// loaded chunk's CSS) or Reduce Motion change. Undefined where nothing can watch (no MutationObserver).
function epochOf(doc: Document): { epoch: number } | undefined {
  const known = epochs.get(doc);
  if (known) return known;
  const view = doc.defaultView;
  const Observer = (view as (Window & typeof globalThis) | null)?.MutationObserver;
  if (!view || !Observer || !doc.documentElement) return undefined;
  const state = { epoch: 0 };
  const bump = () => {
    state.epoch += 1;
    scheduleRewarm(view);
  };
  const observer = new Observer(bump);
  observer.observe(doc.documentElement, { attributes: true });
  if (doc.head) observer.observe(doc.head, { childList: true, subtree: true, characterData: true, attributes: true });
  view.matchMedia?.("(prefers-reduced-motion: reduce)").addEventListener?.("change", bump);
  epochs.set(doc, state);
  return state;
}

/// What over `node` changes its tokens without a sheet or the root changing: a chat's minimal motion and
/// its send entrance. Attribute reads only: no style or layout.
function keyOf(node: Element): string {
  const minimal = node.closest('[data-chat-motion="minimal"]') ? "minimal" : "";
  return `${minimal}|${node.closest("[data-send-entrance]")?.getAttribute("data-send-entrance") ?? ""}`;
}

/// The computed value of the custom property `name` on `node` (trimmed), read through getComputedStyle only
/// the first time for this node, name and key since the page's tokens last changed.
export function motionToken(node: Element, name: string): string {
  const doc = node.ownerDocument;
  const state = epochOf(doc);
  const read = () => doc.defaultView?.getComputedStyle(node).getPropertyValue(name).trim() ?? "";
  if (!state) return read();
  const key = keyOf(node);
  let names = kept.get(node);
  const known = names?.get(name);
  if (known && known.epoch === state.epoch && known.key === key) return known.value;
  const value = read();
  if (!names) kept.set(node, (names = new Map()));
  names.set(name, { epoch: state.epoch, key, value });
  return value;
}

function warmNow(): void {
  for (const [node, names] of warm) {
    if (!node.isConnected) warm.delete(node);
    else for (const name of names) motionToken(node, name);
  }
}

/// Reads the kept nodes' tokens again in an idle moment after the page's tokens changed.
function scheduleRewarm(view: Window): void {
  if (rewarm || warm.size === 0) return;
  const done = () => {
    rewarm = undefined;
    warmNow();
  };
  if (typeof view.requestIdleCallback === "function") {
    const id = view.requestIdleCallback(done, { timeout: 500 });
    rewarm = () => view.cancelIdleCallback(id);
  } else {
    const id = view.setTimeout(done, 50);
    rewarm = () => view.clearTimeout(id);
  }
}

/// Keeps `node`'s `names` read ahead of the moment that needs them (a send's commit): now, in an idle
/// moment, and again after each change of the page's tokens. Returns the call that stops it.
export function warmMotionTokens(node: Element, names: readonly string[]): () => void {
  const view = node.ownerDocument.defaultView;
  if (!view) return () => {};
  warm.set(node, names);
  epochOf(node.ownerDocument);
  scheduleRewarm(view);
  return () => {
    if (warm.get(node) === names) warm.delete(node);
  };
}
