// Leo, 2026-11-18: "when I drag a file into Claude Code, it just, the preview is literally just the
// file path ... you can just have that be the thing that gets attached ... you can just send it
// instantly. Like, stop blocking."
//
// The host pushes a native drop's paths with the drop itself (`cmux-files-dropped`): WebKit gets
// the push before it hands the page the drop (the push is queued in `performDragOperation` ahead of
// the drop), Chromium right after the page's own drop message. Either way the page links a local
// drop's files by path with no request and no deadline, and asks `chat.attach.dropped` only when no
// push comes (an older host). For a chat on another machine the page asks the host to put each
// dropped file there from its path (`chat.upload.begin` naming the push's token): no byte crosses
// the page bridge.
import { afterEach, expect, test } from "bun:test";
import {
  DROP_PUSH_EVENT,
  clearPushedDrops,
  listenForDropPush,
  noteDomDrop,
  pushedDropPaths,
  receivePushedDrop,
  uploadDropped,
} from "../src/agent-session/acpmux/composer/dropPush";

const MB = 1024 * 1024;

/// A file as the page gets it from a drop, whose bytes may never be read.
function bigFile(name: string, size: number, reads: string[]): File {
  const file = new File([], name, { type: "video/quicktime" });
  Object.defineProperty(file, "size", { value: size });
  for (const method of ["arrayBuffer", "text", "stream", "bytes", "slice"] as const)
    Object.defineProperty(file, method, {
      value: () => {
        reads.push(method);
        throw new Error(`read ${method}`);
      },
    });
  return file;
}

afterEach(() => clearPushedDrops());

test("a push that lands before the page's drop links the file by path, with no request", async () => {
  const asked: string[] = [];
  const reads: string[] = [];
  const file = bigFile("Screen Recording.mov", 300 * MB, reads);
  // WebKit: the host's push is queued ahead of the drop.
  receivePushedDrop({ local: true, items: [{ path: "/Users/you/Desktop/Screen Recording.mov", folder: false }] });
  noteDomDrop([file]);
  const started = performance.now();
  const items = await pushedDropPaths([file], async () => {
    asked.push("chat.attach.dropped");
    return undefined;
  });
  expect(performance.now() - started).toBeLessThan(20);
  expect(items).toEqual([{ path: "/Users/you/Desktop/Screen Recording.mov", folder: false }]);
  expect(asked).toEqual([]);
  expect(reads).toEqual([]);
});

test("a push that lands just after the page's drop (Chromium) is used the moment it lands", async () => {
  const file = bigFile("notes.pdf", 2 * MB, []);
  noteDomDrop([file]);
  // The ask answers late (a busy host); the push comes 5 ms after the drop, as Chromium's does.
  // fixed-wait: the ask's late answer is the behavior under test.
  const ask = () => new Promise<undefined>((resolve) => setTimeout(() => resolve(undefined), 2_000));
  // fixed-wait: the push landing 5 ms after the drop is the behavior under test.
  setTimeout(() => receivePushedDrop({ local: true, items: [{ path: "/Users/you/notes.pdf", folder: false }] }), 5);
  const started = performance.now();
  const items = await pushedDropPaths([file], ask);
  expect(performance.now() - started).toBeLessThan(200);
  expect(items).toEqual([{ path: "/Users/you/notes.pdf", folder: false }]);
});

test("an event from the host on the page's window is the push", async () => {
  const file = bigFile("a.txt", 10, []);
  const page = new EventTarget();
  listenForDropPush(page);
  page.dispatchEvent(
    new CustomEvent(DROP_PUSH_EVENT, { detail: { local: true, items: [{ path: "/tmp/x/a.txt", folder: false }] } }),
  );
  expect(await pushedDropPaths([file], async () => undefined)).toEqual([{ path: "/tmp/x/a.txt", folder: false }]);
});

test("with no push (an older host) the page asks chat.attach.dropped as before", async () => {
  const file = bigFile("a.txt", 10, []);
  const asked: string[] = [];
  const items = await pushedDropPaths([file], async () => {
    asked.push("chat.attach.dropped");
    return [{ path: "/Users/you/a.txt", folder: false }];
  });
  expect(asked).toEqual(["chat.attach.dropped"]);
  expect(items).toEqual([{ path: "/Users/you/a.txt", folder: false }]);
});

test("a push for other files, or for a chat on another machine, never links", async () => {
  const file = bigFile("a.txt", 10, []);
  receivePushedDrop({ local: true, items: [{ path: "/Users/you/b.txt", folder: false }] });
  receivePushedDrop({ local: false, items: [{ path: "/Users/you/a.txt", folder: false, token: "drop-1" }] });
  expect(await pushedDropPaths([file], async () => undefined)).toBeUndefined();
});

test("WebKit's folder (name.zip, from the folder's path) links as a folder", async () => {
  const file = bigFile("Project.zip", 0, []);
  receivePushedDrop({ local: true, items: [{ path: "/Users/you/Project", folder: false }] });
  expect(await pushedDropPaths([file], async () => undefined)).toEqual([{ path: "/Users/you/Project", folder: true }]);
});

test("a remote chat's drop goes to its machine from the path: no chunk crosses the page bridge", async () => {
  const reads: string[] = [];
  const file = bigFile("clip.mov", 200 * MB, reads);
  const calls: [string, Record<string, unknown>][] = [];
  const call = async (method: string, params: Record<string, unknown>) => {
    calls.push([method, params]);
    if (method === "chat.upload.begin" && params.batchToken === "drop-abc")
      return { path: "/srv/session/uploads/clip.mov" };
    throw Object.assign(new Error("not expected"), { code: "upload_failed" });
  };
  const fallback: File[][] = [];
  receivePushedDrop({ local: false, items: [{ path: "/Users/you/clip.mov", folder: false, token: "drop-abc" }] });
  noteDomDrop([file]);
  const done: number[] = [];
  const sent = await uploadDropped(
    [file],
    call,
    async (files) => {
      fallback.push(files);
      return undefined;
    },
    () => false,
    (index, at) => at === 1 && done.push(index),
  );
  expect(sent).toEqual({ paths: ["/srv/session/uploads/clip.mov"] });
  expect(calls).toEqual([["chat.upload.begin", { name: "clip.mov", size: 200 * MB, batchToken: "drop-abc" }]]);
  expect(fallback).toEqual([]);
  expect(reads).toEqual([]);
  expect(done).toEqual([0]);
});

test("a remote paste (no drop) uploads through the bridge at once, never waiting for a push", async () => {
  const file = bigFile("pasted.bin", 1 * MB, []);
  const fallback: File[][] = [];
  const started = performance.now();
  const sent = await uploadDropped(
    [file],
    async () => ({}),
    async (files) => {
      fallback.push(files);
      return { paths: ["/srv/pasted.bin"] };
    },
  );
  expect(performance.now() - started).toBeLessThan(20);
  expect(fallback).toEqual([[file]]);
  expect(sent).toEqual({ paths: ["/srv/pasted.bin"] });
});

test("a drop mixing pushed and unknown files puts the known one and uploads the rest", async () => {
  const known = bigFile("a.mov", 5 * MB, []);
  const unknown = bigFile("b.bin", 5 * MB, []);
  receivePushedDrop({ local: false, items: [{ path: "/Users/you/a.mov", folder: false, token: "drop-a" }] });
  noteDomDrop([known, unknown]);
  const sent = await uploadDropped(
    [known, unknown],
    async (method, params) => (method === "chat.upload.begin" ? { path: `/srv/${String(params.name)}` } : {}),
    async (files) => ({ paths: files.map((file) => `/srv/bridge/${file.name}`) }),
  );
  expect(sent).toEqual({ paths: ["/srv/a.mov", "/srv/bridge/b.bin"] });
});

test("the tile's x cancels the put by its token", async () => {
  const file = bigFile("big.mov", 900 * MB, []);
  const calls: [string, Record<string, unknown>][] = [];
  let finish: (value: unknown) => void = () => {};
  const call = (method: string, params: Record<string, unknown>) => {
    calls.push([method, params]);
    if (method === "chat.upload.begin") return new Promise((resolve) => (finish = resolve));
    if (method === "chat.upload.cancel")
      finish(Promise.reject(Object.assign(new Error("cancelled"), { code: "cancelled" })));
    return Promise.resolve(null);
  };
  receivePushedDrop({ local: false, items: [{ path: "/Users/you/big.mov", folder: false, token: "drop-x" }] });
  noteDomDrop([file]);
  let removed = false;
  const listeners: (() => void)[] = [];
  const cancelled = Object.assign(() => removed, {
    subscribe: (_index: number, changed: () => void) => {
      listeners.push(changed);
      return () => {};
    },
  });
  const sending = uploadDropped([file], call, async () => undefined, cancelled);
  // fixed-wait: the put is under way (its begin is in flight) before the tile's x.
  await new Promise((resolve) => setTimeout(resolve, 5));
  removed = true;
  for (const changed of listeners) changed();
  expect(await sending).toEqual({ paths: [""] });
  expect(calls.map(([method, params]) => [method, params.batchToken ?? params.token])).toEqual([
    ["chat.upload.begin", "drop-x"],
    ["chat.upload.cancel", "drop-x"],
  ]);
});

test("a host that cannot put from a path (unsupported) falls back to the bridge upload", async () => {
  const file = bigFile("c.mov", 5 * MB, []);
  receivePushedDrop({ local: false, items: [{ path: "/Users/you/c.mov", folder: false, token: "drop-c" }] });
  noteDomDrop([file]);
  const fallback: File[][] = [];
  const sent = await uploadDropped(
    [file],
    async () => {
      throw Object.assign(new Error("no"), { code: "unsupported" });
    },
    async (files) => {
      fallback.push(files);
      return { paths: ["/srv/bridge/c.mov"] };
    },
  );
  expect(fallback).toEqual([[file]]);
  expect(sent).toEqual({ paths: ["/srv/bridge/c.mov"] });
});
