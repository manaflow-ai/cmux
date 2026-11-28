/// A save on macOS reaches Vite at once, not up to 115 ms later. Vite's watcher (chokidar 3) uses the
/// `fsevents` package there, whose stream is created with a 0.1 s latency: a save is reported at the
/// next 100 ms tick, so half of all saves waited about 100 ms before Vite even knew (capture Mac,
/// 2026-11-22: Vite's change event 1-115 ms after the write, p50 77 ms; one recursive `fs.watch` of
/// the same folder, 2-27 ms). Every hot update waited that long before its module was rebuilt.
///
/// One recursive `fs.watch` of the root (a single FSEvents stream in libuv, constant cost however many
/// files the root has) reports a save of a module the page has loaded as soon as it lands, as the
/// watcher's own `change` (and `all`) event, so everything that listens to the watcher (Vite's hot
/// update, the dev-server plugins) runs as before, only earlier. chokidar's own event for the same
/// version of the file comes later and is dropped: each version (the file's mtime) is reported once.
/// Files outside the module graph (a config, a watched asset) keep chokidar's path. Other platforms
/// (inotify on Linux) report saves at once already and are left alone.
import fs from "node:fs";
import path from "node:path";
import type { Plugin } from "vite";

/// The part of chokidar's watcher this uses: its `emit`, which every event goes through.
export type EventSource = { emit(event: string | symbol, ...args: unknown[]): boolean };
/// `fs.watch` as this uses it (tests pass their own).
export type RecursiveWatch = (
  root: string,
  options: { recursive: true },
  listener: (event: string, name: string | Buffer | null) => void,
) => { close(): void; on(event: "error", listener: (error: Error) => void): unknown };

/// The file's mtime in ms, undefined when it cannot be read (a save that removed it).
const mtimeOf = (file: string): number | undefined => {
  try {
    return fs.statSync(file).mtimeMs;
  } catch {
    return undefined;
  }
};

/// Reports each save under `root` of a file `loaded` says the page imports on `watcher` as soon as
/// `watch` sees it, and drops the watcher's own later event for the same version. Returns the stop.
export function reportSavesEarly(
  watcher: EventSource,
  root: string,
  loaded: (file: string) => boolean,
  watch: RecursiveWatch = fs.watch as unknown as RecursiveWatch,
  mtime: (file: string) => number | undefined = mtimeOf,
): () => void {
  // The version of each file already reported, per event name (`change`, then chokidar's `all`).
  const reported = { change: new Map<string, number>(), all: new Map<string, number>() };
  const emit = watcher.emit.bind(watcher);
  // A change of `file` at `version` is new to `seen` (and now recorded there).
  const fresh = (seen: Map<string, number>, file: string, version: number | undefined) => {
    if (version === undefined) return true;
    if (seen.get(file) === version) return false;
    seen.set(file, version);
    return true;
  };
  watcher.emit = (event, ...args) => {
    // chokidar: emit("change", path, stats), then emit("all", "change", path, stats).
    const file = event === "change" ? args[0] : event === "all" && args[0] === "change" ? args[1] : undefined;
    if (typeof file === "string") {
      const seen = event === "change" ? reported.change : reported.all;
      if (!fresh(seen, path.resolve(file), mtime(file))) return false;
    }
    return emit(event, ...args);
  };
  let stream: ReturnType<RecursiveWatch> | undefined;
  try {
    stream = watch(root, { recursive: true }, (_event, name) => {
      if (!name) return;
      const file = path.join(root, name.toString());
      if (file.includes(`${path.sep}node_modules${path.sep}`) || file.includes(`${path.sep}.git${path.sep}`)) return;
      if (!loaded(file)) return;
      const version = mtime(file);
      if (version === undefined) return;
      if (!fresh(reported.change, file, version)) return;
      reported.all.set(file, version);
      emit("change", file);
      emit("all", "change", file);
    });
    // A stream that fails (the folder went away) leaves chokidar's path, as before.
    stream.on("error", () => stream?.close());
  } catch {
    stream = undefined;
  }
  return () => {
    stream?.close();
    watcher.emit = emit;
  };
}

/// The dev server's plugin: ``reportSavesEarly`` on the server's watcher, macOS only.
export function fastSaveWatch(platform: NodeJS.Platform = process.platform): Plugin {
  return {
    name: "cmux-dev-fast-save-watch",
    apply: "serve",
    configureServer(server) {
      // `server.watch: null` (a test's server) has no watcher to speed up.
      if (platform !== "darwin" || server.config.server.watch === null) return;
      const graph = server.environments?.client?.moduleGraph ?? server.moduleGraph;
      const stop = reportSavesEarly(
        server.watcher,
        server.config.root,
        (file) => (graph.getModulesByFile(file)?.size ?? 0) > 0,
      );
      server.httpServer?.on("close", stop);
    },
  };
}
