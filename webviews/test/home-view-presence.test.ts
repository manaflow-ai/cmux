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

type Request = { cmd: string; params?: Record<string, unknown> };

function fakeDaemon(capabilities: string[], hold?: Promise<void>) {
  const requests: Request[] = [];
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
          return { entries: [{ conversation: "conv_cloud", title: "Team", kind: "group", last_seq: 1 }] };
        case "cloud-conversation-subscribe":
          if (hold) await hold;
          return { state: "live" };
        case "cloud-conversation-snapshot":
          throw new Error("no heads here");
        default:
          return {};
      }
    },
    onEvent: () => () => {},
    onClose: () => () => {},
  } as unknown as DaemonSocket;
  return { socket, requests };
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
