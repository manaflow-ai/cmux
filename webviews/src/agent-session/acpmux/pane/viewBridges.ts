// Each pane view's bridge in a shared pane document (goal memory-per-chat, paneView.ts): a chat
// mounted as a view registers the bridge its pane installed under its view, so a host event that
// names one chat (a command, a turn to reveal, a dictation update) reaches that chat and no other.
// `window.cmuxAcpmuxBridge` stays the document's, which is every page today (one chat a page), and
// the page's own null view still reads it.
import "./bridgeGlobals";

export type AcpmuxBridge = NonNullable<Window["cmuxAcpmuxBridge"]>;

const bridges = new Map<string, AcpmuxBridge>();

/// Registers `bridge` as `view`'s; the returned function forgets it (only if it is still the one).
export function registerViewBridge(view: string, bridge: AcpmuxBridge): () => void {
  bridges.set(view, bridge);
  return () => {
    if (bridges.get(view) === bridge) bridges.delete(view);
  };
}

/// The bridge a host event for `view` goes to: the document's for the page's own null view, else
/// the view's own. A view with none registered (not mounted yet, or closed) gets nothing, never
/// another chat's bridge.
export function bridgeFor(view: string | null): AcpmuxBridge | undefined {
  return view === null ? window.cmuxAcpmuxBridge : bridges.get(view);
}

/// Tests and diagnostics: the views with a registered bridge.
export function bridgeViews(): string[] {
  return [...bridges.keys()];
}
