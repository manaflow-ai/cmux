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
  SNAPSHOT_REPORTED_GLOBAL,
  isChatSnapshot,
  misfit,
  type SnapshotLive,
} from "./shared";

const globals = self as unknown as Record<string, unknown>;

/// A call id no page client counts up to (pageClient.ts starts at 1), for the one call this script makes.
const BOOT_CALL_ID = 2 ** 30;

/// Tells the host the copy is on screen (`pane.painted`, as live.ts `reportChatSnapshot` does when the bundle
/// starts), from this small script: the host shows the page as the copy drew, not after the bundle (megabytes
/// of script) was fetched, parsed and evaluated. Only before the bundle started (it reports itself after), and
/// not in a parked pooled document, whose calls wait for its claim (pageClient.ts PARKED_NAME). The same two
/// hosts as native.ts: the shared page host's `cmuxPage` envelope, else the legacy `agentSession` handler.
function reportShown(): void {
  try {
    if (globals[SNAPSHOT_REPORTED_GLOBAL] === true || globals.__cmuxPageParked === true) return;
    const handlers = (
      globals.webkit as { messageHandlers?: Record<string, { postMessage?: (body: unknown) => unknown } | undefined> }
    )?.messageHandlers;
    const params = { drewKeptTail: true };
    const page = handlers?.cmuxPage;
    const legacy = handlers?.agentSession;
    let sent: unknown;
    if (typeof page?.postMessage === "function")
      sent = page.postMessage({ t: "call", id: BOOT_CALL_ID, op: "cmux.agent.pane.painted", params });
    else if (typeof legacy?.postMessage === "function")
      sent = legacy.postMessage({ id: crypto.randomUUID?.() ?? String(BOOT_CALL_ID), method: "pane.painted", params });
    else return;
    globals[SNAPSHOT_REPORTED_GLOBAL] = true;
    (sent as Promise<unknown> | undefined)?.catch?.(() => undefined);
  } catch {
    // The bundle reports it when it starts.
  }
}

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
    else if (
      !paintSnapshot(document, value, {
        // The live side as it is when the copy's sheet loaded: the bundle may have started since.
        wanted: () => !(globals[SNAPSHOT_LIVE_GLOBAL] as SnapshotLive | undefined)?.drawn,
        shown: () => {
          const painted = (globals[SNAPSHOT_LIVE_GLOBAL] as SnapshotLive | undefined)?.painted;
          if (painted) painted();
          else reportShown();
        },
      })
    )
      globals[SNAPSHOT_MISS_GLOBAL] = misfit(value, document) ?? "engine";
  } catch (error) {
    // A copy that cannot draw leaves the page to open as it does with none.
    globals[SNAPSHOT_MISS_GLOBAL] = `error: ${String(error)}`;
  }
}
globals[SNAPSHOT_BOOT_GLOBAL] = boot;
if (SNAPSHOT_GLOBAL in globals) boot();
