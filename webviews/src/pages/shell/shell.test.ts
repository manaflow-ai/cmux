import { afterEach, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { BridgePageClient, isPageError, type ReplyHandler } from "../shared/pageClient";
import { PageShell, ShellOps, type ShellContext, type ShellPage, type ShellPageModule } from "./shell";

// The shell's claim and reset over the real bridge client: the host's calls arrive as
// `__cmuxPageReceive` envelopes and the replies go back through the reply handler.

interface Deferred {
  resolve(value: unknown): void;
}

class FakeHost implements ReplyHandler {
  readonly posts: any[] = [];
  readonly replies: any[] = [];
  readonly deferred = new Map<number, Deferred>();
  readonly streams = new Map<number, string>();
  private nextSub = 1;

  postMessage(body: any): Promise<unknown> {
    this.posts.push(body);
    if (body.t === "ok" || body.t === "err") {
      this.replies.push(body);
      return Promise.resolve(null);
    }
    if (body.t === "unsub") {
      this.streams.delete(body.sub);
      return Promise.resolve(null);
    }
    if (body.t === "sub") {
      const sub = this.nextSub++;
      this.streams.set(sub, body.stream);
      return Promise.resolve({ t: "ok", id: body.id, value: { sub } });
    }
    // Calls stay pending until the test answers them.
    return new Promise((resolve) => this.deferred.set(body.id, { resolve }));
  }

  answer(id: number, value: unknown): void {
    this.deferred.get(id)?.resolve({ t: "ok", id, value });
    this.deferred.delete(id);
  }
}

class FakeIDB {
  names = new Set<string>();
  deleted: string[] = [];
  databases = async () => [...this.names].map((name) => ({ name }));
  deleteDatabase = (name: string) => {
    this.names.delete(name);
    this.deleted.push(name);
    const request = {} as { onsuccess?: () => void };
    queueMicrotask(() => request.onsuccess?.());
    return request as unknown as IDBOpenDBRequest;
  };
}

class FakeCaches {
  keysList = new Set<string>();
  keys = async () => [...this.keysList];
  delete = async (key: string) => this.keysList.delete(key);
}

let dom: JSDOM;
let host: FakeHost;
let client: BridgePageClient;
let shell: PageShell;
let idb: FakeIDB;
let caches: FakeCaches;
let contexts: Record<string, ShellContext>;
let unmounts: string[];
let nextCallId = 1000;

let mounts: string[];
let paints: string[];
let resumes: { id: string; context: unknown; route: string }[];

function probe(id: string): ShellPage {
  const module: ShellPageModule = {
    mount(root, ctx) {
      contexts[id] = ctx;
      mounts.push(id);
      root.textContent = id;
      return {
        unmount: () => void unmounts.push(id),
        resume: (context: unknown, route: string) => void resumes.push({ id, context, route }),
      } as ReturnType<ShellPageModule["mount"]>;
    },
  };
  return { id, load: async () => module };
}

async function hostCall(op: string, params: unknown = {}): Promise<any> {
  const id = nextCallId++;
  const before = host.replies.length;
  client.receive({ t: "call", id, op, params });
  for (let i = 0; i < 20 && host.replies.length === before; i++) await Promise.resolve();
  for (let i = 0; i < 20 && !host.replies.some((reply) => reply.id === id); i++)
    await new Promise((r) => setTimeout(r, 0));
  return host.replies.find((reply) => reply.id === id);
}

beforeEach(async () => {
  dom = new JSDOM(
    "<!doctype html><html lang='en' data-cmux-page='shell'><head><title></title></head><body><main id='root'></main></body></html>",
    {
      url: "https://shell.invalid/",
    },
  );
  host = new FakeHost();
  idb = new FakeIDB();
  caches = new FakeCaches();
  Object.defineProperty(dom.window, "indexedDB", { value: idb, configurable: true });
  Object.defineProperty(dom.window, "caches", { value: caches, configurable: true });
  client = new BridgePageClient(host, dom.window as unknown as Record<string, unknown>);
  contexts = {};
  unmounts = [];
  mounts = [];
  paints = [];
  resumes = [];
  shell = new PageShell({
    client,
    root: dom.window.document.getElementById("root")!,
    pages: [probe("cmux.a"), probe("cmux.b")],
    win: dom.window as any,
    languages: () => ["en"],
    painted: () => void paints.push(shell.current ?? ""),
  });
  await shell.preload();
});

afterEach(() => dom.window.close());

test("a claim mounts a preloaded page synchronously and replies with its id", async () => {
  client.receive({ t: "call", id: 1, op: ShellOps.claim, params: { page: "cmux.a", route: "#/x", context: { n: 1 } } });
  // Synchronous: the page is in the DOM before any microtask runs.
  expect(dom.window.document.querySelector("[data-shell-page='cmux.a']")?.textContent).toBe("cmux.a");
  expect(contexts["cmux.a"].route).toBe("#/x");
  expect(contexts["cmux.a"].context).toEqual({ n: 1 });
  await Promise.resolve();
  await Promise.resolve();
  expect(host.replies.find((reply) => reply.id === 1)).toEqual({ t: "ok", id: 1, value: { page: "cmux.a" } });
  expect(shell.current).toBe("cmux.a");
});

test("an unknown page is refused", async () => {
  const reply = await hostCall(ShellOps.claim, { page: "com.example.app" });
  expect(reply.t).toBe("err");
  expect(shell.current).toBeNull();
});

test("a reset leaves the next page nothing of the last one", async () => {
  await hostCall(ShellOps.claim, { page: "cmux.a" });
  const a = contexts["cmux.a"];
  const win = dom.window as any;
  win.localStorage.setItem("secret", "a");
  win.sessionStorage.setItem("secret", "a");
  idb.names.add("a-db");
  caches.keysList.add("a-cache");
  win.leakedByA = { token: "a" };
  a.style(".a { color: red }");
  dom.window.document.title = "A";
  dom.window.document.documentElement.lang = "ja";
  // A pending call and a subscription made through the page's client.
  const pending = a.client.call("cmux.a.slow", {});
  const outcome = pending.then(
    () => "resolved",
    (error) => (isPageError(error) ? error.code : "other"),
  );
  const events: unknown[] = [];
  await a.client.subscribe("cmux.a.events", (data) => events.push(data));
  const slowId = host.posts.find((post) => post.op === "cmux.a.slow").id;
  const [sub] = [...host.streams.keys()];

  const reply = await hostCall(ShellOps.reset);
  expect(reply).toEqual({ t: "ok", id: reply.id, value: { reset: true } });
  expect(unmounts).toEqual(["cmux.a"]);
  expect(await outcome).toBe("cmux.protocol.closed");
  // The stream was closed with the host, and a late event reaches no one.
  expect(host.streams.has(sub)).toBe(false);
  client.receive({ t: "ev", sub, seq: 1, data: { late: true } });
  expect(events).toEqual([]);
  // A late reply of the old call changes nothing.
  host.answer(slowId, { late: true });
  await Promise.resolve();

  await hostCall(ShellOps.claim, { page: "cmux.b" });
  expect(win.localStorage.length).toBe(0);
  expect(win.sessionStorage.length).toBe(0);
  expect(await idb.databases()).toEqual([]);
  expect(idb.deleted).toEqual(["a-db"]);
  expect(await caches.keys()).toEqual([]);
  expect(win.leakedByA).toBeUndefined();
  expect(dom.window.document.head.querySelector("style")).toBeNull();
  expect(dom.window.document.title).toBe("");
  expect(dom.window.document.documentElement.lang).toBe("en");
  expect(dom.window.document.querySelector("[data-shell-page='cmux.a']")).toBeNull();
  expect(dom.window.document.querySelector("[data-shell-page='cmux.b']")).not.toBeNull();
  // The old client stays closed for good.
  await expect(a.client.call("cmux.a.again", {})).rejects.toMatchObject({ code: "cmux.protocol.closed" });
});

test("a subscribe in flight during a reset is closed when it opens", async () => {
  await hostCall(ShellOps.claim, { page: "cmux.a" });
  const subscribing = contexts["cmux.a"].client.subscribe("cmux.a.events", () => undefined);
  await hostCall(ShellOps.reset);
  await expect(subscribing).rejects.toMatchObject({ code: "cmux.protocol.closed" });
  expect(host.streams.size).toBe(0);
});

test("a claim while a page is mounted resets the old page first", async () => {
  await hostCall(ShellOps.claim, { page: "cmux.a" });
  (dom.window as any).localStorage.setItem("k", "a");
  const reply = await hostCall(ShellOps.claim, { page: "cmux.b" });
  expect(reply.t).toBe("ok");
  expect(unmounts).toEqual(["cmux.a"]);
  expect((dom.window as any).localStorage.length).toBe(0);
  expect(shell.current).toBe("cmux.b");
});

test("the shell's own boot globals survive a reset", async () => {
  (dom.window as any).bootGlobal = 1;
  shell.keepCurrentGlobals();
  await hostCall(ShellOps.claim, { page: "cmux.a" });
  await hostCall(ShellOps.reset);
  expect((dom.window as any).bootGlobal).toBe(1);
  expect(typeof (dom.window as any).__cmuxPageReceive).toBe("function");
});

test("a prepared page is mounted with no context, and the claim only resumes it", async () => {
  const prepared = await hostCall(ShellOps.claim, { page: "cmux.a", route: "", context: null, prepare: true });
  expect(prepared).toEqual({ t: "ok", id: prepared.id, value: { page: "cmux.a", prepared: true } });
  expect(contexts["cmux.a"].context).toBeNull();
  const reply = await hostCall("page.resume", { page: "cmux.a", route: "#/x", context: { session: 1 } });
  expect(reply.value).toEqual({ page: "cmux.a" });
  // No second mount: the claim only hands the session to the mounted page.
  expect(mounts).toEqual(["cmux.a"]);
  expect(resumes).toEqual([{ id: "cmux.a", context: { session: 1 }, route: "#/x" }]);
});

test("resuming a page that is not the prepared one is refused", async () => {
  await hostCall(ShellOps.claim, { page: "cmux.a", prepare: true });
  const reply = await hostCall("page.resume", { page: "cmux.b", context: {} });
  expect(reply.t).toBe("err");
  expect(resumes).toEqual([]);
});

test("a resume that arrives while its prepare claim waits for the last reset waits for it", async () => {
  await hostCall(ShellOps.claim, { page: "cmux.a" });
  // The reset leaves cleanup pending, so the prepare claim mounts later.
  client.receive({ t: "call", id: 7001, op: ShellOps.reset, params: {} });
  client.receive({ t: "call", id: 7002, op: ShellOps.claim, params: { page: "cmux.b", prepare: true } });
  client.receive({ t: "call", id: 7003, op: "page.resume", params: { page: "cmux.b", context: { s: 2 } } });
  for (let i = 0; i < 20 && !host.replies.some((reply) => reply.id === 7003); i++)
    await new Promise((r) => setTimeout(r, 0));
  expect(host.replies.find((reply) => reply.id === 7003)?.value).toEqual({ page: "cmux.b" });
  expect(resumes).toEqual([{ id: "cmux.b", context: { s: 2 }, route: "" }]);
});

test("the host hears of the first frame after a claim and after a resume, never after a prepare", async () => {
  await hostCall(ShellOps.claim, { page: "cmux.a" });
  expect(paints).toEqual(["cmux.a"]);
  await hostCall(ShellOps.reset);
  await hostCall(ShellOps.claim, { page: "cmux.b", prepare: true });
  expect(paints).toEqual(["cmux.a"]);
  await hostCall("page.resume", { page: "cmux.b", context: {} });
  expect(paints).toEqual(["cmux.a", "cmux.b"]);
});
