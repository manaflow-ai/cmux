// dev-server/fastSaveWatch.ts: a save of a loaded module reaches the watcher's listeners at once, and
// the watcher's own later event for that version is dropped; anything else keeps the watcher's path.
import { expect, test } from "bun:test";
import { EventEmitter } from "node:events";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { reportSavesEarly, type RecursiveWatch } from "../dev-server/fastSaveWatch";

const root = "/repo/webviews";

function harness(loaded: (file: string) => boolean = () => true) {
  const watcher = new EventEmitter();
  const seen: string[] = [];
  watcher.on("change", (file: string) => seen.push(`change ${file}`));
  watcher.on("all", (event: string, file: string) => seen.push(`all ${event} ${file}`));
  const mtimes = new Map<string, number>();
  let listener: ((event: string, name: string | null) => void) | undefined;
  let closed = false;
  const watch: RecursiveWatch = (watched, options, onEvent) => {
    expect(watched).toBe(root);
    expect(options.recursive).toBe(true);
    listener = onEvent;
    return { close: () => (closed = true), on: () => undefined };
  };
  const stop = reportSavesEarly(watcher, root, loaded, watch, (file) => mtimes.get(file));
  // chokidar's own report: change, then all.
  const chokidar = (file: string) => {
    watcher.emit("change", file, {});
    watcher.emit("all", "change", file, {});
  };
  return {
    watcher,
    seen,
    mtimes,
    save: (name: string) => listener?.("change", name),
    chokidar,
    stop,
    closed: () => closed,
  };
}

test("a save of a loaded module is reported once, early, and the watcher's own event for it is dropped", () => {
  const h = harness();
  const file = path.join(root, "src/App.tsx");
  h.mtimes.set(file, 1);
  h.save("src/App.tsx");
  expect(h.seen).toEqual([`change ${file}`, `all change ${file}`]);
  h.chokidar(file);
  h.save("src/App.tsx"); // FSEvents can repeat an event for the same version
  expect(h.seen).toEqual([`change ${file}`, `all change ${file}`]);
});

test("the next save of the same file is a new version and is reported again", () => {
  const h = harness();
  const file = path.join(root, "src/App.tsx");
  h.mtimes.set(file, 1);
  h.save("src/App.tsx");
  h.chokidar(file);
  h.mtimes.set(file, 2);
  h.chokidar(file); // the watcher saw this one first: it passes, and the early report is the duplicate
  h.save("src/App.tsx");
  expect(h.seen).toEqual([`change ${file}`, `all change ${file}`, `change ${file}`, `all change ${file}`]);
});

test("a file the page has not loaded, node_modules and .git keep the watcher's own path", () => {
  const app = path.join(root, "src/App.tsx");
  const h = harness((file) => file !== app);
  for (const name of ["src/App.tsx", "node_modules/react/index.js", ".git/index"]) {
    h.mtimes.set(path.join(root, name), 1);
    h.save(name);
  }
  expect(h.seen).toEqual([]);
  h.chokidar(app);
  expect(h.seen).toEqual([`change ${app}`, `all change ${app}`]);
});

test("a removed file is not reported early; the watcher's own events always pass", () => {
  const h = harness();
  const file = path.join(root, "src/Gone.tsx");
  h.save("src/Gone.tsx");
  expect(h.seen).toEqual([]);
  h.watcher.emit("unlink", file);
  h.chokidar(file);
  expect(h.seen).toEqual([`change ${file}`, `all change ${file}`]);
});

test("stop closes the stream and gives the watcher its own emit back", () => {
  const h = harness();
  const file = path.join(root, "src/App.tsx");
  h.mtimes.set(file, 1);
  h.save("src/App.tsx");
  h.stop();
  expect(h.closed()).toBe(true);
  h.chokidar(file);
  expect(h.seen.filter((line) => line.startsWith("change"))).toHaveLength(2);
});

test("with the real fs.watch, a write is reported on the watcher", async () => {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "fast-save-watch-")));
  try {
    fs.mkdirSync(path.join(dir, "src"));
    const file = path.join(dir, "src/App.tsx");
    fs.writeFileSync(file, "export const a = 1;\n");
    const watcher = new EventEmitter();
    const got = new Promise<string>((resolve) => watcher.on("change", resolve));
    const stop = reportSavesEarly(watcher, dir, (candidate) => candidate === file);
    // The stream can start after a first write: save a new version every 50 ms until one is reported.
    let version = 2;
    const saves = setInterval(() => fs.writeFileSync(file, `export const a = ${version++};\n`), 50);
    try {
      expect(await got).toBe(file);
    } finally {
      clearInterval(saves);
      stop();
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
