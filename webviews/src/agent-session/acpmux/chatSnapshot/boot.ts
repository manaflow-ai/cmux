// The agent page's first classic script (build-agent-pane-web.sh bundles it as chat-snapshot.js,
// after `<main id="root">` and before pane.js): draws the chat's snapshot that the host's
// `__snapshot/chat.js` set just before it, in the document's first frame (paint.ts). A page with
// none, or with one for another size, look or theme, draws nothing here and opens as before.
import { paintSnapshot } from "./paint";
import { SNAPSHOT_GLOBAL, isChatSnapshot } from "./shared";

try {
  const value = (self as unknown as Record<string, unknown>)[SNAPSHOT_GLOBAL];
  if (isChatSnapshot(value)) paintSnapshot(document, value);
} catch {
  // A copy that cannot draw leaves the page to open as it does with none.
}
