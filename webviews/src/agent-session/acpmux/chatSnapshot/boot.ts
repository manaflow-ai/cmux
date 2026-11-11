// The agent page's first classic script (build-agent-pane-web.sh bundles it as chat-snapshot.js,
// after `<main id="root">` and before pane.js): draws the chat's snapshot that the host's
// `__snapshot/chat.js` sets (paint.ts). That script loads `async`, so neither the document nor the
// bundle waits on the host's answer (a busy main thread at launch answers late): it calls the boot
// once it set the globals, and the boot runs now if it came first. A copy that comes after the live
// page drew the chat draws nothing. A page with none, or with one for another size or theme, draws
// nothing here and opens as before.
import { paintSnapshot } from "./paint";
import {
  SNAPSHOT_BOOT_GLOBAL,
  SNAPSHOT_GLOBAL,
  SNAPSHOT_LIVE_GLOBAL,
  SNAPSHOT_MISS_GLOBAL,
  isChatSnapshot,
  misfit,
  type SnapshotLive,
} from "./shared";

const globals = self as unknown as Record<string, unknown>;
let booted = false;
function boot(): void {
  if (booted) return;
  booted = true;
  try {
    const value = globals[SNAPSHOT_GLOBAL];
    const live = globals[SNAPSHOT_LIVE_GLOBAL] as SnapshotLive | undefined;
    // Why nothing drew, for the page's own record (live.ts `chatSnapshotReport`).
    if (value === null || value === undefined) globals[SNAPSHOT_MISS_GLOBAL] = "none served";
    else if (!isChatSnapshot(value)) globals[SNAPSHOT_MISS_GLOBAL] = "not a snapshot of this version";
    else if (live?.drawn) globals[SNAPSHOT_MISS_GLOBAL] = "late: the page drew the chat first";
    else if (!paintSnapshot(document, value)) globals[SNAPSHOT_MISS_GLOBAL] = misfit(value, document) ?? "engine";
    else live?.painted?.();
  } catch (error) {
    // A copy that cannot draw leaves the page to open as it does with none.
    globals[SNAPSHOT_MISS_GLOBAL] = `error: ${String(error)}`;
  }
}
globals[SNAPSHOT_BOOT_GLOBAL] = boot;
if (SNAPSHOT_GLOBAL in globals) boot();
