// A save no longer waits behind a re-read of its whole folder. Vite's watcher (chokidar 3, bundled in
// vite-plus) watches each folder with fs.watch and, on any event in it, a content change of one file
// included, re-reads the folder (readdirp: an lstat, a filter match and path math per entry) to find
// added and removed files. src/agent-session/acpmux/ holds about 1,260 files, so every save there ran
// about 40 ms of that on the dev server's only thread, in 8–12 ms slices, during the very request
// the page makes for the saved module: its fetch reached the server 12–18 ms late and its
// transform ran 17–30 ms against a 6 ms floor (web_swap loop of goal dev-loop-ceiling, 2026-11-27).
// The changed file's own event does not need the re-read (its watcher reports the change), so the
// re-read now runs RESCAN_DELAY_MS after the folder's last event, one per burst: adds and removes
// show up that much later, and a save's update and transform run first.
import type { Plugin } from "vite-plus";

export const RESCAN_DELAY_MS = 200;

type HandleRead = (directory: string, initialAdd: boolean, ...rest: unknown[]) => unknown;

/** Wraps chokidar's NodeFsHandler#_handleRead so later re-reads of one folder are coalesced and
 *  delayed; the first (initial) read is untouched. Returns false when the watcher has no such
 *  method (a chokidar change), leaving it as it was. */
export function deferRescans(watcher: unknown, delayMs = RESCAN_DELAY_MS): boolean {
  const handler = (watcher as { _nodeFsHandler?: { _handleRead?: HandleRead } } | null)?._nodeFsHandler;
  const original = handler?._handleRead;
  if (!handler || typeof original !== "function") return false;
  // One pending re-read per registration, not per folder: chokidar watches a folder once per path that
  // reaches it (the root itself, and with `target` set for a watched path inside it that does not exist
  // yet, such as Vite's public/), and each registration's read finds different entries.
  const pending = new Map<object, Map<string, ReturnType<typeof setTimeout>>>();
  handler._handleRead = function (this: unknown, ...args: Parameters<HandleRead>) {
    const [directory, initialAdd, wh, target, dir, depth] = args;
    if (initialAdd) return original.apply(this, args);
    const owner = (wh && typeof wh === "object" ? wh : handler) as object;
    const byKey = pending.get(owner) ?? new Map<string, ReturnType<typeof setTimeout>>();
    pending.set(owner, byKey);
    const key = JSON.stringify([directory, target ?? null, dir ?? null, depth ?? null]);
    clearTimeout(byKey.get(key));
    const timer = setTimeout(() => {
      byKey.delete(key);
      if (!byKey.size) pending.delete(owner);
      if (!(watcher as { closed?: boolean }).closed) void original.apply(handler, args);
    }, delayMs);
    timer.unref?.();
    byKey.set(key, timer);
    return undefined;
  };
  return true;
}

export function deferDirRescan(): Plugin {
  return {
    name: "cmux-defer-dir-rescan",
    apply: "serve",
    configureServer(server) {
      if (!deferRescans(server.watcher))
        server.config.logger.warn(
          "Vite's watcher has no _nodeFsHandler._handleRead; dev-server/deferDirRescan.ts left folder re-reads on the save path",
        );
    },
  };
}
