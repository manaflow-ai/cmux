// The agent page's first classic script (build-agent-pane-web.sh bundles it as chat-snapshot.js,
// after `<main id="root">` and before pane.js): draws the chat's snapshot that the host's
// `__snapshot/chat.js` set just before it, in the document's first frame (paint.ts). A page with
// none, or with one for another size, look or theme, draws nothing here and opens as before.
import { paintSnapshot } from "./paint";
import { SNAPSHOT_GLOBAL, SNAPSHOT_MISS_GLOBAL, isChatSnapshot, misfit } from "./shared";

const globals = self as unknown as Record<string, unknown>;
try {
  const value = globals[SNAPSHOT_GLOBAL];
  // Why nothing drew, for the page's own record (live.ts `chatSnapshotReport`).
  if (value === null || value === undefined) globals[SNAPSHOT_MISS_GLOBAL] = "none served";
  else if (!isChatSnapshot(value)) globals[SNAPSHOT_MISS_GLOBAL] = "not a snapshot of this version";
  else if (!paintSnapshot(document, value)) globals[SNAPSHOT_MISS_GLOBAL] = misfit(value, document) ?? "engine";
} catch (error) {
  // A copy that cannot draw leaves the page to open as it does with none.
  globals[SNAPSHOT_MISS_GLOBAL] = `error: ${String(error)}`;
}
