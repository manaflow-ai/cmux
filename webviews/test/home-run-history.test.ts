// Silent Chief runs are not represented by a posted reply. They must still be found when Home
// restores a conversation and when the person pages back to the question that started one.
import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { MockPageStreams } from "../src/pages/shared/pageStreams";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = { window: scope.window, document: scope.document };
scope.window = dom.window;
scope.document = dom.window.document;
afterAll(() => {
  Object.assign(scope, saved);
  dom.window.close();
});

const { HomeChannelsStore } = await import("../src/pages/home-channels/store");
const { DaemonHomeClient } = await import("../src/pages/home-channels/daemonHome");
const { HomeOps } = await import("../src/pages/home-channels/types");
type Message = import("../src/pages/home-channels/types").HomeMessage;
type Run = import("../src/pages/home-channels/types").HomeRun;

const me = { id: "me", kind: "human" as const, name: "Me", chief: false };
const chief = { id: "chief", kind: "agent" as const, name: "Chief", chief: true };
const message = (seq: number): Message => ({
  id: `m${seq}`,
  conversation: "chief-conv",
  seq,
  author: seq % 2 ? "me" : "chief",
  createdAt: seq,
  retracted: false,
  parts: [{ type: "text", text: `message ${seq}`, mentions: [] }],
  reactions: [],
});
const run = (index: number, answer: string): Run => ({
  id: `r${index}`,
  conversation: "chief-conv",
  author: "chief",
  status: "done",
  startedAt: index + 1,
  updatedAt: index + 1,
  rev: 1,
  stepCount: index === 1 ? 1 : 0,
  answers: [answer],
});

function client(all: Message[], allRuns: Run[]) {
  const streams = new MockPageStreams();
  const calls: { op: string; params: Record<string, unknown> }[] = [];
  const conversation = {
    id: "chief-conv",
    owner: "local",
    title: "Chief",
    kind: "chief" as const,
    participants: [me, chief],
    lastSeq: all.at(-1)?.seq ?? 0,
    rev: all.at(-1)?.seq ?? 0,
    updatedAt: all.at(-1)?.createdAt ?? 0,
    unread: 0,
    mentions: 0,
    muted: false,
    pinned: false,
  };
  const page = (params: Record<string, unknown>) => all.slice(-(Number(params.tail) || 100));
  const api = {
    async call<R>(op: string, raw: unknown): Promise<R> {
      const params = (raw ?? {}) as Record<string, unknown>;
      calls.push({ op, params });
      if (op === HomeOps.inbox)
        return { me, conversations: [conversation], rev: conversation.rev } as R;
      if (op === HomeOps.page) return { conversation, messages: page(params) } as R;
      if (op === HomeOps.history) {
        const before = Number(params.beforeSeq) || Number.MAX_SAFE_INTEGER;
        const limit = Number(params.limit) || 100;
        const messages = all
          .filter((entry) => entry.seq < before)
          .sort((a, b) => b.seq - a.seq)
          .slice(0, limit);
        return { messages: messages.reverse(), threads: [] } as R;
      }
      if (op === HomeOps.attachmentSupport) return { local: false, cloud: false } as R;
      if (op === HomeOps.runs) {
        const before =
          typeof params.beforeStartedAt === "number"
            ? params.beforeStartedAt
            : Number.MAX_SAFE_INTEGER;
        const limit = Number(params.limit) || 50;
        const available = allRuns
          .filter((entry) => entry.startedAt < before)
          .sort((a, b) => b.startedAt - a.startedAt);
        return { runs: available.slice(0, limit), hasMore: available.length > limit } as R;
      }
      if (op === HomeOps.run) {
        const entry = allRuns.find((candidate) => candidate.id === params.run);
        return {
          run: entry,
          steps:
            entry?.id === "r1"
              ? [
                  {
                    id: "report:a1:1:0",
                    seq: 1,
                    rev: 1,
                    at: 2,
                    kind: "note",
                    text: "[a1] report",
                    attachments: [],
                    links: [],
                  },
                ]
              : [],
          hasMore: false,
        } as R;
      }
      return {} as R;
    },
    async subscribe<E>(
      stream: string,
      onEvent: (data: E, seq: number) => void,
    ): Promise<() => void> {
      return (
        streams.subscribe(stream, onEvent as (data: unknown, seq: number) => void) ?? (() => {})
      );
    },
    handle: () => () => {},
  };
  return { api, calls };
}

function waitForReport(store: {
  runs: {
    get(
      conversation: string,
      author: string,
      id: string,
    ): { steps: readonly { text?: string }[] } | undefined;
    subscribe(listener: () => void): () => void;
  };
}): Promise<void> {
  if (store.runs.get("chief-conv", "chief", "r1")?.steps[0]?.text === "[a1] report")
    return Promise.resolve();
  return new Promise((resolve) => {
    const stop = store.runs.subscribe(() => {
      if (store.runs.get("chief-conv", "chief", "r1")?.steps[0]?.text !== "[a1] report") return;
      stop();
      resolve();
    });
  });
}

test("reload pages past twenty newer runs to restore a silent report", async () => {
  const all = Array.from({ length: 26 }, (_, index) => message(index + 1));
  const allRuns = [
    run(1, "m1"),
    ...Array.from({ length: 25 }, (_, index) => run(index + 2, `m${index + 2}`)),
  ];
  const fake = client(all, allRuns);
  const store = new HomeChannelsStore(fake.api as never);
  const stop = store.subscribe(() => {});
  await store.start();
  await waitForReport(store);
  expect(
    fake.calls
      .filter((call) => call.op === HomeOps.runs)
      .some((call) => call.params.beforeStartedAt !== undefined),
  ).toBe(true);
  expect(store.runs.get("chief-conv", "chief", "r1")?.steps[0]?.text).toBe("[a1] report");
  stop();
});

test("loadOlder finds a silent run attached to the newly loaded question", async () => {
  const all = Array.from({ length: 130 }, (_, index) => message(index + 1));
  const allRuns = [
    run(1, "m1"),
    ...Array.from({ length: 25 }, (_, index) => run(index + 2, `m${index + 2}`)),
  ];
  const fake = client(all, allRuns);
  const store = new HomeChannelsStore(fake.api as never);
  const stop = store.subscribe(() => {});
  await store.start();
  expect(store.getSnapshot().messages[0]?.id).toBe("m31");
  await store.loadOlder();
  await waitForReport(store);
  expect(store.getSnapshot().messages[0]?.id).toBe("m1");
  expect(store.runs.get("chief-conv", "chief", "r1")?.steps[0]?.text).toBe("[a1] report");
  stop();
});

test("cloud run pages forward the cursor and keep a skewed second agent paginable", async () => {
  const requests: { command: string; params: Record<string, unknown> }[] = [];
  const raw = (id: string, author: string, started: number) => ({
    id,
    conversation: "cloud-conv",
    author,
    status: "done",
    started_at: started,
    updated_at: started,
    rev: 1,
    step_count: 0,
    answers: [],
  });
  const byAgent: Record<string, ReturnType<typeof raw>[]> = {
    agent_a: [raw("a3", "agent_a", 30), raw("a2", "agent_a", 20), raw("a1", "agent_a", 10)],
    agent_b: [raw("b3", "agent_b", 25), raw("b2", "agent_b", 15), raw("b1", "agent_b", 5)],
  };
  const socket = {
    async request<T>(command: string, params: Record<string, unknown> = {}): Promise<T> {
      requests.push({ command, params });
      if (command === "identify") return { capabilities: ["cloud-conversation-runs-v1"] } as T;
      if (command !== "cloud-conversation-runs") return {} as T;
      const before =
        typeof params.before_started_at === "number"
          ? params.before_started_at
          : Number.MAX_SAFE_INTEGER;
      const runs = (byAgent[String(params.agent)] ?? []).filter(
        (entry) => entry.started_at < before,
      );
      return {
        runs: runs.slice(0, Number(params.limit)),
        has_more: runs.length > Number(params.limit),
      } as T;
    },
  };
  const home = new DaemonHomeClient(socket as never);
  const cloud = (
    home as unknown as {
      cloud: {
        known: Set<string>;
        entries: Map<string, Record<string, unknown>>;
        heads: Map<string, Record<string, unknown>>;
      };
    }
  ).cloud;
  cloud.known.add("cloud-conv");
  cloud.entries.set("cloud-conv", { conversation: "cloud-conv", kind: "group", title: "Cloud" });
  cloud.heads.set("cloud-conv", {
    id: "cloud-conv",
    participants: [
      { id: "agent_a", kind: "agent", display_name: "A" },
      { id: "agent_b", kind: "agent", display_name: "B" },
    ],
  });
  const first = await home.call<{ runs: Run[]; hasMore: boolean }>(HomeOps.runs, {
    conversation: "cloud-conv",
    limit: 2,
  });
  expect(first.runs.map((entry) => entry.id)).toEqual(["a3", "b3", "a2"]);
  expect(first.hasMore).toBe(true);
  const second = await home.call<{ runs: Run[]; hasMore: boolean }>(HomeOps.runs, {
    conversation: "cloud-conv",
    limit: 2,
    beforeStartedAt: 25,
  });
  expect(second.runs.map((entry) => entry.id)).toEqual(["a2", "b2"]);
  expect(
    requests
      .filter((request) => request.command === "cloud-conversation-runs")
      .every(
        (request) =>
          request.params.before_started_at === undefined || request.params.before_started_at === 25,
      ),
  ).toBe(true);
});
