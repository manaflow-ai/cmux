// The sending side of viewing presence (chat multiplayer): the page tells the Cloud owner which
// conversation the person views (`cmux.home.view` -> `cloud-conversation-presence`), only for a
// Cloud conversation and only through a daemon that names `cloud-conversation-presence-v1`.
import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = { window: scope.window, document: scope.document };
scope.window = dom.window;
scope.document = dom.window.document;
afterAll(() => Object.assign(scope, saved));

let visibility: "visible" | "hidden" = "visible";
Object.defineProperty(dom.window.document, "visibilityState", { configurable: true, get: () => visibility });
const setVisibility = (state: "visible" | "hidden") => {
  visibility = state;
  dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
};

const { HomeChannelsStore } = await import("../src/pages/home-channels/store");
const { DaemonHomeClient } = await import("../src/pages/home-channels/daemonHome");
const { HomeOps } = await import("../src/pages/home-channels/types");
const { PAGE_CONNECTION } = await import("../src/pages/shared/pageStreams");
type Conversation = import("../src/pages/home-channels/types").HomeConversation;
type DaemonSocket = import("../src/pages/shared/daemonSocket").DaemonSocket;

const me = { id: "user_local", kind: "human" as const, name: "Me", chief: false };
const row = (id: string, owner: "local" | "cloud", kind: Conversation["kind"]): Conversation => ({
  id,
  owner,
  title: id,
  kind,
  participants: [me],
  lastSeq: 0,
  rev: 0,
  updatedAt: 0,
  unread: 0,
  mentions: 0,
  muted: false,
  pinned: false,
});
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

test("the store says which Cloud conversation the person views, and never a local one", async () => {
  const conversations = [
    row("local-chief", "local", "chief"),
    row("cloud-a", "cloud", "group"),
    row("cloud-b", "cloud", "direct"),
  ];
  const views: [string, boolean][] = [];
  const client = {
    async call(op: string, params: { conversation?: string; viewing?: boolean }) {
      if (op === HomeOps.inbox) return { me, conversations, rev: 0 };
      if (op === HomeOps.page)
        return { conversation: conversations.find((c) => c.id === params.conversation), messages: [] };
      if (op === HomeOps.view) views.push([params.conversation!, params.viewing!]);
      return {};
    },
    async subscribe() {
      return () => {};
    },
    handle: () => () => {},
  };
  const store = new HomeChannelsStore(client as never);
  store.routed = false;
  const stop = store.subscribe(() => {});
  await store.start();
  // The first pick is the local Chief: nothing goes out.
  expect(store.getSnapshot().selected).toBe("local-chief");
  expect(views).toEqual([]);

  await store.select("cloud-a");
  expect(views).toEqual([["cloud-a", true]]);
  await store.select("cloud-b");
  expect(views).toEqual([
    ["cloud-a", true],
    ["cloud-a", false],
    ["cloud-b", true],
  ]);

  views.length = 0;
  setVisibility("hidden");
  expect(views).toEqual([["cloud-b", false]]);
  // Switching while hidden says nothing; showing the page says the open one.
  await store.select("cloud-a");
  expect(views).toEqual([["cloud-b", false]]);
  setVisibility("visible");
  expect(views).toEqual([
    ["cloud-b", false],
    ["cloud-a", true],
  ]);

  // The narrow page's list pane covers the conversation: not viewing.
  views.length = 0;
  store.setShown(false);
  store.setShown(true);
  expect(views).toEqual([
    ["cloud-a", false],
    ["cloud-a", true],
  ]);

  // A local conversation ends the Cloud viewing and sends nothing of its own.
  views.length = 0;
  await store.select("local-chief");
  expect(views).toEqual([["cloud-a", false]]);

  // The page closing ends the viewing.
  await store.select("cloud-b");
  views.length = 0;
  dom.window.dispatchEvent(new dom.window.Event("pagehide"));
  expect(views).toEqual([["cloud-b", false]]);
  // Torn down after that: nothing more goes out.
  views.length = 0;
  stop();
  expect(views).toEqual([]);
});

test("the store stops viewing when it is torn down", async () => {
  const views: [string, boolean][] = [];
  const conversations = [row("cloud-a", "cloud", "chief")];
  const client = {
    async call(op: string, params: { conversation?: string; viewing?: boolean }) {
      if (op === HomeOps.inbox) return { me, conversations, rev: 0 };
      if (op === HomeOps.page) return { conversation: conversations[0], messages: [] };
      if (op === HomeOps.view) views.push([params.conversation!, params.viewing!]);
      return {};
    },
    async subscribe() {
      return () => {};
    },
    handle: () => () => {},
  };
  const store = new HomeChannelsStore(client as never);
  store.routed = false;
  const stop = store.subscribe(() => {});
  await store.start();
  expect(views).toEqual([["cloud-a", true]]);
  stop();
  expect(views).toEqual([
    ["cloud-a", true],
    ["cloud-a", false],
  ]);
});

/** A page client over `conversations` that records the views, the calls and each stream's
 *  handler; `answer` is what `cmux.home.view` answers. */
function fakeClient(
  conversations: Conversation[],
  answer: (conversation: string, viewing: boolean) => unknown = () => ({}),
) {
  const views: [string, boolean][] = [];
  const calls: string[] = [];
  const streams = new Map<string, (data: unknown) => void>();
  const client = {
    async call(op: string, params: { conversation?: string; viewing?: boolean }) {
      calls.push(op);
      if (op === HomeOps.inbox) return { me, conversations, rev: 0 };
      if (op === HomeOps.page)
        return { conversation: conversations.find((c) => c.id === params.conversation), messages: [] };
      if (op === HomeOps.view) {
        views.push([params.conversation!, params.viewing!]);
        return answer(params.conversation!, params.viewing!);
      }
      return {};
    },
    async subscribe(stream: string, onEvent: (data: unknown) => void) {
      streams.set(stream, onEvent);
      return () => {};
    },
    handle: () => () => {},
  };
  return { client, views, calls, streams };
}

async function started(client: unknown) {
  const store = new HomeChannelsStore(client as never);
  store.routed = false;
  const stop = store.subscribe(() => {});
  await store.start();
  return { store, stop };
}

test("an open Cloud row that leaves the list (removed, archived) ends the viewing", async () => {
  const { client, views, streams } = fakeClient([row("cloud-a", "cloud", "chief"), row("cloud-b", "cloud", "group")]);
  const { store, stop } = await started(client);
  expect(store.getSnapshot().selected).toBe("cloud-a");
  expect(views).toEqual([["cloud-a", true]]);
  // Another row's change says nothing; the open row's removal says it is no longer viewed.
  streams.get(HomeOps.events)!({ removed: ["cloud-b"] });
  expect(views).toEqual([["cloud-a", true]]);
  streams.get(HomeOps.events)!({ removed: ["cloud-a"] });
  expect(views).toEqual([
    ["cloud-a", true],
    ["cloud-a", false],
  ]);
  stop();
  expect(views).toHaveLength(2);
});

test("a teardown while the page's subscribes are pending installs nothing and says nothing", async () => {
  const { client, views, calls } = fakeClient([row("cloud-a", "cloud", "chief")]);
  let release = () => {};
  const held = new Promise<void>((resolve) => (release = resolve));
  let stopped = 0;
  client.subscribe = async (stream: string) => {
    if (stream === HomeOps.events) await held;
    return () => void stopped++;
  };
  const store = new HomeChannelsStore(client as never);
  store.routed = false;
  const stop = store.subscribe(() => {});
  const starting = store.start();
  await tick();
  stop();
  release();
  await starting;
  // Both streams it opened are closed again, and the inbox was never read.
  expect(stopped).toBe(2);
  expect(calls).not.toContain(HomeOps.inbox);
  setVisibility("hidden");
  setVisibility("visible");
  dom.window.dispatchEvent(new dom.window.Event("pagehide"));
  await store.select("cloud-a");
  expect(views).toEqual([]);
});

test("a reconnect says the viewing again (the daemon ended it with the old connection)", async () => {
  const { client, views, streams } = fakeClient([row("cloud-a", "cloud", "chief")]);
  const { stop } = await started(client);
  expect(views).toEqual([["cloud-a", true]]);
  streams.get(PAGE_CONNECTION)!({ connected: false });
  expect(views).toEqual([["cloud-a", true]]);
  streams.get(PAGE_CONNECTION)!({ connected: true });
  await tick();
  await tick();
  expect(views).toEqual([
    ["cloud-a", true],
    ["cloud-a", true],
  ]);
  stop();
});

test("a viewing the owner did not take is said again on the next show", async () => {
  let sent = false;
  const { client, views } = fakeClient([row("cloud-a", "cloud", "chief")], () => ({ sent }));
  const { stop } = await started(client);
  await tick();
  expect(views).toEqual([["cloud-a", true]]);
  // Never heard, so hiding sends no "stopped"; showing says it again.
  sent = true;
  setVisibility("hidden");
  setVisibility("visible");
  await tick();
  expect(views).toEqual([
    ["cloud-a", true],
    ["cloud-a", true],
  ]);
  setVisibility("hidden");
  expect(views.at(-1)).toEqual(["cloud-a", false]);
  setVisibility("visible");
  stop();
});

test("a late refusal of an older attempt leaves the newer viewing as sent", async () => {
  let refuse = (_answer: unknown) => {};
  const first = new Promise((resolve) => (refuse = resolve));
  let calls = 0;
  const { client, views } = fakeClient([row("cloud-a", "cloud", "chief"), row("cloud-b", "cloud", "group")], () =>
    calls++ === 0 ? first : { sent: true },
  );
  const { store, stop } = await started(client);
  // A (its answer pending), then B, then A again, which the owner takes.
  await store.select("cloud-b");
  await store.select("cloud-a");
  expect(views.at(-1)).toEqual(["cloud-a", true]);
  // The first A attempt's refusal arrives last: it says nothing about the newer one.
  refuse({ sent: false });
  await tick();
  views.length = 0;
  await store.select("cloud-b");
  expect(views).toEqual([
    ["cloud-a", false],
    ["cloud-b", true],
  ]);
  stop();
});

test("an inbox reload that drops the open Cloud row, with nothing to open instead, ends the viewing", async () => {
  const conversations = [row("cloud-a", "cloud", "chief")];
  const { client, views, streams } = fakeClient(conversations);
  const { stop } = await started(client);
  expect(views).toEqual([["cloud-a", true]]);
  conversations.length = 0;
  streams.get(HomeOps.events)!({ inboxStale: true });
  await tick();
  await tick();
  expect(views).toEqual([
    ["cloud-a", true],
    ["cloud-a", false],
  ]);
  stop();
  expect(views).toHaveLength(2);
});

test("the New and Edit Chief pages cover the conversation: not viewed while one is open", async () => {
  const { client, views } = fakeClient([row("cloud-a", "cloud", "chief")]);
  const { store, stop } = await started(client);
  expect(views).toEqual([["cloud-a", true]]);
  store.sheets.show({ kind: "newChief" });
  expect(views.at(-1)).toEqual(["cloud-a", false]);
  store.sheets.show({ kind: "editChief", chief: "chief_1" });
  expect(views).toHaveLength(2);
  store.sheets.close();
  expect(views).toEqual([
    ["cloud-a", true],
    ["cloud-a", false],
    ["cloud-a", true],
  ]);
  stop();
});

type Request = { cmd: string; params?: Record<string, unknown> };

function fakeDaemon(
  capabilities: string[],
  hold?: Promise<void>,
  { cloud = ["conv_cloud"], refuse = 0 }: { cloud?: string[]; refuse?: number } = {},
) {
  const requests: Request[] = [];
  let refusals = refuse;
  const listeners = new Set<(event: Record<string, unknown>) => void>();
  const emit = (event: Record<string, unknown>) => listeners.forEach((listener) => listener(event));
  const socket = {
    async request(cmd: string, params?: Record<string, unknown>): Promise<unknown> {
      requests.push({ cmd, params });
      switch (cmd) {
        case "identify":
          return { capabilities };
        case "conversation-list":
          return { conversations: [] };
        case "cloud-session-status":
          return { state: "active", participant: "user_cloudperson0000000" };
        case "cloud-inbox-list":
          return { entries: cloud.map((id) => ({ conversation: id, title: id, kind: "group", last_seq: 1 })) };
        case "cloud-conversation-subscribe":
          if (hold) await hold;
          if (refusals > 0) {
            refusals--;
            throw new Error("at_capacity");
          }
          return { state: "live" };
        case "cloud-conversation-snapshot":
          return { messages: [] };
        default:
          return {};
      }
    },
    onEvent: (listener: (event: Record<string, unknown>) => void) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    onClose: () => () => {},
  } as unknown as DaemonSocket;
  return { socket, requests, emit };
}

const presenceSent = (requests: Request[]) =>
  requests.filter((r) => r.cmd === "cloud-conversation-presence").map((r) => r.params);

test("daemonHome sends presence for a Cloud conversation after its subscribe, in order", async () => {
  let release = () => {};
  const hold = new Promise<void>((resolve) => (release = resolve));
  const { socket, requests } = fakeDaemon(["ws-cloud-conversations-v1", "cloud-conversation-presence-v1"], hold);
  const home = new DaemonHomeClient(socket);
  await home.call(HomeOps.inbox, {});
  // Open then leave before the subscribe answers: true goes out after it, then false.
  const opened = home.call<{ sent: boolean }>(HomeOps.view, { conversation: "conv_cloud", viewing: true });
  const left = home.call<{ sent: boolean }>(HomeOps.view, { conversation: "conv_cloud", viewing: false });
  await tick();
  expect(presenceSent(requests)).toEqual([]);
  release();
  expect(await opened).toEqual({ sent: true });
  expect(await left).toEqual({ sent: true });
  const subscribeAt = requests.findIndex((r) => r.cmd === "cloud-conversation-subscribe");
  const presenceAt = requests.findIndex((r) => r.cmd === "cloud-conversation-presence");
  expect(subscribeAt).toBeGreaterThanOrEqual(0);
  expect(presenceAt).toBeGreaterThan(subscribeAt);
  expect(presenceSent(requests)).toEqual([
    { conversation: "conv_cloud", viewing: true },
    { conversation: "conv_cloud", viewing: false },
  ]);
  // A local conversation has no viewing presence.
  const local = await home.call<{ sent: boolean }>(HomeOps.view, { conversation: "conv_local", viewing: true });
  expect(local).toEqual({ sent: false });
  expect(presenceSent(requests)).toHaveLength(2);
});

test("daemonHome sends no presence through a daemon without the capability", async () => {
  const { socket, requests } = fakeDaemon(["ws-cloud-conversations-v1"]);
  const home = new DaemonHomeClient(socket);
  await home.call(HomeOps.inbox, {});
  const cloud = await home.call<{ sent: boolean }>(HomeOps.view, { conversation: "conv_cloud", viewing: true });
  expect(cloud).toEqual({ sent: false });
  expect(presenceSent(requests)).toEqual([]);
  expect(requests.some((r) => r.cmd === "cloud-conversation-subscribe")).toBe(false);
});

test("daemonHome echoes cloud-conversation-presence-v1 so the daemon relays the event", async () => {
  const { socket, requests } = fakeDaemon(["ws-cloud-conversations-v1", "cloud-conversation-presence-v1"]);
  const home = new DaemonHomeClient(socket);
  const off = await home.subscribe(HomeOps.events, () => {});
  const info = requests.find((r) => r.cmd === "set-client-info");
  expect(info?.params?.capabilities).toContain("cloud-conversation-presence-v1");
  expect(info?.params?.capabilities).toContain("cloud-conversation-typing-v1");
  off();
});

const PRESENCE = ["ws-cloud-conversations-v1", "cloud-conversation-presence-v1"];
const sentFor = (requests: Request[], cmd: string) =>
  requests.filter((r) => r.cmd === cmd).map((r) => r.params?.conversation);

test("daemonHome sends no presence for a refused subscribe, and the next view subscribes again", async () => {
  const { socket, requests } = fakeDaemon(PRESENCE, undefined, { refuse: 1 });
  const home = new DaemonHomeClient(socket);
  await home.call(HomeOps.inbox, {});
  const refused = await home.call<{ sent: boolean }>(HomeOps.view, { conversation: "conv_cloud", viewing: true });
  expect(refused).toEqual({ sent: false });
  expect(presenceSent(requests)).toEqual([]);
  const again = await home.call<{ sent: boolean }>(HomeOps.view, { conversation: "conv_cloud", viewing: true });
  expect(again).toEqual({ sent: true });
  expect(sentFor(requests, "cloud-conversation-subscribe")).toEqual(["conv_cloud", "conv_cloud"]);
  expect(presenceSent(requests)).toEqual([{ conversation: "conv_cloud", viewing: true }]);
});

test("the subscription cap never evicts the conversation the person views", async () => {
  const cloud = Array.from({ length: 20 }, (_, i) => `conv_${i}`);
  const { socket, requests } = fakeDaemon(PRESENCE, undefined, { cloud });
  const home = new DaemonHomeClient(socket);
  await home.call(HomeOps.inbox, {});
  const viewed = await home.call<{ sent: boolean }>(HomeOps.view, { conversation: "conv_0", viewing: true });
  expect(viewed).toEqual({ sent: true });
  // 18 more reads: past the cap of 16, the least recent ones the person does not view end.
  for (const id of cloud.slice(1, 19)) await home.call(HomeOps.page, { conversation: id });
  expect(sentFor(requests, "cloud-conversation-unsubscribe")).toEqual(["conv_1", "conv_2", "conv_3"]);
  // Once the person leaves it, it is the least recent again and goes first.
  await home.call(HomeOps.view, { conversation: "conv_0", viewing: false });
  await home.call(HomeOps.page, { conversation: "conv_19" });
  expect(sentFor(requests, "cloud-conversation-unsubscribe")).toEqual(["conv_1", "conv_2", "conv_3", "conv_0"]);
});

test("a conversation socket the daemon closed is subscribed again before the next presence", async () => {
  const { socket, requests, emit } = fakeDaemon(PRESENCE);
  const home = new DaemonHomeClient(socket);
  const off = await home.subscribe(HomeOps.events, () => {});
  await home.call(HomeOps.inbox, {});
  const view = () => home.call<{ sent: boolean }>(HomeOps.view, { conversation: "conv_cloud", viewing: true });
  expect(await view()).toEqual({ sent: true });
  emit({ event: "cloud-subscription-state", scope: "conversation", state: "closed", conversation: "conv_cloud" });
  expect(await view()).toEqual({ sent: true });
  expect(sentFor(requests, "cloud-conversation-subscribe")).toEqual(["conv_cloud", "conv_cloud"]);
  const cmds = requests.map((r) => r.cmd);
  expect(cmds.lastIndexOf("cloud-conversation-presence")).toBeGreaterThan(
    cmds.lastIndexOf("cloud-conversation-subscribe"),
  );
  off();
});
