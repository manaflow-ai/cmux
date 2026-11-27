// A failed Cloud read is not a sign-out (audit 2026-11-18 section 17, class G): the Channels page
// keeps the last good Cloud rows and says why the read failed, and only a status that answers
// "not signed in" empties the Cloud inbox. Before, an unanswered `cloud-session-status` read was
// taken as signed out and the Cloud rows went blank until some later relist.
import { expect, test } from "bun:test";
import { CloudHome } from "../src/pages/home-channels/cloudHome";
import { conversation } from "../src/pages/home-channels/daemonHome";
import type { DaemonSocket } from "../src/pages/shared/daemonSocket";

type Answer = (cmd: string) => unknown;

const entry = (id: string, title: string) => ({
  conversation: id,
  kind: "channel",
  title,
  last_seq: 1,
  last_at: "2026-11-18T10:00:00Z",
  unread: 0,
  mentions: 0,
  pinned: false,
});

/** A daemon socket whose answers the test swaps between reads. */
function daemon(first: Answer) {
  let answer = first;
  const socket = {
    async request(cmd: string): Promise<unknown> {
      if (cmd === "cloud-inbox-subscribe") return {};
      return answer(cmd);
    },
  } as unknown as DaemonSocket;
  return { socket, answer: (next: Answer) => (answer = next) };
}

const good: Answer = (cmd) => {
  if (cmd === "cloud-session-status") return { state: "active", participant: "user_cloudperson0000000" };
  if (cmd === "cloud-inbox-list") return { entries: [entry("conv_a", "launch"), entry("conv_b", "design")] };
  throw new Error(`not served: ${cmd}`);
};

/** Quiet the warning each failed read logs, and keep what it said. */
async function logged<T>(run: () => Promise<T>): Promise<{ value: T; warnings: string[] }> {
  const warnings: string[] = [];
  const warn = console.warn;
  console.warn = (...args: unknown[]) => void warnings.push(args.map(String).join(" "));
  try {
    return { value: await run(), warnings };
  } finally {
    console.warn = warn;
  }
}

test("a failing Cloud status read after a good list keeps the rows and says why", async () => {
  const { socket, answer } = daemon(good);
  const cloud = new CloudHome(socket, conversation, () => {});
  expect((await cloud.inbox(true)).map((row) => row.id).sort()).toEqual(["conv_a", "conv_b"]);
  expect(cloud.failure()).toBeNull();

  // The inbox is listed again (a reset, a closed inbox socket) and the status read fails.
  cloud.reset();
  answer(() => {
    throw new Error("timed out after 10 s");
  });
  const { value: rows, warnings } = await logged(() => cloud.inbox(true));
  expect(rows.map((row) => row.id).sort()).toEqual(["conv_a", "conv_b"]);
  expect(cloud.failure()).toBe("timed out after 10 s");
  expect(warnings).toEqual(["[home-channels] Cloud cloud-session-status failed: timed out after 10 s"]);

  // The next read answers: the failure goes and the list is current again.
  answer(good);
  expect((await cloud.inbox(true)).length).toBe(2);
  expect(cloud.failure()).toBeNull();
});

test("a failing Cloud inbox list keeps the last good rows and sets the failure", async () => {
  const { socket, answer } = daemon(good);
  const cloud = new CloudHome(socket, conversation, () => {});
  await cloud.inbox(true);
  cloud.reset();
  answer((cmd) => {
    if (cmd === "cloud-session-status") return { state: "active", participant: "user_cloudperson0000000" };
    throw new Error("cloud unreachable");
  });
  const { value: rows } = await logged(() => cloud.inbox(true));
  expect(rows.length).toBe(2);
  expect(cloud.failure()).toBe("cloud unreachable");
});

test("a status that answers signed out still empties the Cloud inbox", async () => {
  const { socket, answer } = daemon(good);
  const cloud = new CloudHome(socket, conversation, () => {});
  await cloud.inbox(true);
  cloud.reset();
  answer((cmd) => {
    if (cmd === "cloud-session-status") return { state: "signed_out" };
    throw new Error(`not served: ${cmd}`);
  });
  expect(await cloud.inbox(true)).toEqual([]);
  expect(cloud.failure()).toBeNull();
});

test("a failed read is tried once per inbox read, not in a burst", async () => {
  let reads = 0;
  const { socket } = daemon((cmd) => {
    if (cmd === "cloud-session-status") reads++;
    throw new Error("offline");
  });
  const cloud = new CloudHome(socket, conversation, () => {});
  await logged(() => cloud.inbox(true));
  expect(reads).toBe(1);
  expect(cloud.failure()).toBe("offline");
});

test("the page keeps the rows, shows the reason and retries with backoff until a read answers", async () => {
  const { JSDOM } = await import("jsdom");
  const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
  const scope = globalThis as Record<string, unknown>;
  const saved = { window: scope.window, document: scope.document, setTimeout: scope.setTimeout };
  scope.window = dom.window;
  scope.document = dom.window.document;
  // The retries are captured, not waited for: each one runs when the test says.
  const timers: { ms: number; run: () => void }[] = [];
  scope.setTimeout = ((run: () => void, ms: number) => timers.push({ ms, run })) as unknown as typeof setTimeout;
  try {
    const { HomeChannelsStore, CLOUD_RETRY_FIRST_MS } = await import("../src/pages/home-channels/store");
    const { HomeOps } = await import("../src/pages/home-channels/types");
    const me = { id: "user_local", kind: "human" as const, name: "Me", chief: false };
    const row = {
      id: "conv_a",
      owner: "cloud" as const,
      title: "launch",
      kind: "group" as const,
      participants: [me],
      lastSeq: 1,
      rev: 1,
      updatedAt: 1,
      unread: 0,
      mentions: 0,
      muted: false,
      pinned: false,
    };
    let cloudError: string | undefined = "timed out after 10 s";
    const client = {
      async call(op: string) {
        if (op === HomeOps.inbox) return { me, conversations: [row], rev: 1, ...(cloudError ? { cloudError } : {}) };
        if (op === HomeOps.page) return { conversation: row, messages: [] };
        return {};
      },
      async subscribe() {
        return () => {};
      },
      handle: () => () => {},
    };
    const store = new HomeChannelsStore(client as never);
    const stop = store.subscribe(() => {});
    await store.start();
    expect(store.getSnapshot().conversations.has("conv_a")).toBe(true);
    expect(store.getSnapshot().cloudError).toBe("timed out after 10 s");
    const retries = () => timers.filter((timer) => timer.ms >= CLOUD_RETRY_FIRST_MS).map((timer) => timer.ms);
    expect(retries()).toEqual([2_000]);

    // Still failing: the next wait doubles.
    timers.find((timer) => timer.ms === 2_000)!.run();
    const realTimeout = saved.setTimeout as typeof setTimeout;
    await new Promise((resolve) => realTimeout(resolve, 10));
    expect(retries()).toEqual([2_000, 4_000]);

    // A read answers: the failure goes, the rows stay, no retry is left waiting.
    cloudError = undefined;
    await store.reloadInbox();
    expect(store.getSnapshot().cloudError).toBeUndefined();
    expect(store.getSnapshot().conversations.has("conv_a")).toBe(true);
    expect(retries()).toEqual([2_000, 4_000]);
    stop();
  } finally {
    Object.assign(scope, saved);
    dom.window.close();
  }
});
