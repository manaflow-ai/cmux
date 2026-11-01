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
const run = (index: number, answer: string, startedAt = index + 1): Run => ({
  id: `r${index}`,
  conversation: "chief-conv",
  author: "chief",
  status: "done",
  startedAt,
  updatedAt: startedAt,
  rev: 1,
  stepCount: index === 1 ? 1 : 0,
  answers: [answer],
});

function client(all: Message[], allRuns: Run[], answerLookup = true) {
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
      if (op === HomeOps.inbox) return { me, conversations: [conversation], rev: conversation.rev } as R;
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
        const answers = Array.isArray(params.answers) ? new Set(params.answers.map(String)) : undefined;
        if (answers)
          return {
            runs: answerLookup ? allRuns.filter((entry) => entry.answers.some((answer) => answers.has(answer))) : [],
            hasMore: false,
            answersComplete: answerLookup,
          } as R;
        if (Array.isArray(params.turns))
          return {
            runs: allRuns.filter((entry) => entry.turn && (params.turns as string[]).includes(entry.turn)),
            hasMore: false,
          } as R;
        const before = typeof params.beforeStartedAt === "number" ? params.beforeStartedAt : Number.MAX_SAFE_INTEGER;
        const limit = Number(params.limit) || 50;
        const available = allRuns.filter((entry) => entry.startedAt < before).sort((a, b) => b.startedAt - a.startedAt);
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
    async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
      return streams.subscribe(stream, onEvent as (data: unknown, seq: number) => void) ?? (() => {});
    },
    handle: () => () => {},
  };
  return { api, calls };
}

function waitForReport(store: {
  runs: {
    get(conversation: string, author: string, id: string): { steps: readonly { text?: string }[] } | undefined;
    subscribe(listener: () => void): () => void;
  };
}): Promise<void> {
  if (store.runs.get("chief-conv", "chief", "r1")?.steps[0]?.text === "[a1] report") return Promise.resolve();
  return new Promise((resolve) => {
    const stop = store.runs.subscribe(() => {
      if (store.runs.get("chief-conv", "chief", "r1")?.steps[0]?.text !== "[a1] report") return;
      stop();
      resolve();
    });
  });
}

// Await the actual history tasks rather than stopping as soon as the first row appears.
function trackRunLoads(store: InstanceType<typeof HomeChannelsStore>): () => Promise<void> {
  const internal = store as unknown as {
    loadRuns(conversation: string, messages: readonly Message[], newest: boolean): Promise<void>;
  };
  const original = internal.loadRuns.bind(store);
  const loads: Promise<void>[] = [];
  internal.loadRuns = (...args) => {
    const load = original(...args);
    loads.push(load);
    return load;
  };
  return async () => {
    await Promise.all(loads);
  };
}

test("reload pages past twenty newer runs to restore a silent report", async () => {
  const all = Array.from({ length: 26 }, (_, index) => message(index + 1));
  const allRuns = [run(1, "m1"), ...Array.from({ length: 25 }, (_, index) => run(index + 2, `m${index + 2}`))];
  const fake = client(all, allRuns, false);
  const store = new HomeChannelsStore(fake.api as never);
  const stop = store.subscribe(() => {});
  await store.start();
  await waitForReport(store);
  expect(
    fake.calls.filter((call) => call.op === HomeOps.runs).some((call) => call.params.beforeStartedAt !== undefined),
  ).toBe(true);
  expect(store.runs.get("chief-conv", "chief", "r1")?.steps[0]?.text).toBe("[a1] report");
  stop();
});

test("answer lookup restores a silent report older than the message window", async () => {
  const all = Array.from({ length: 26 }, (_, index) => message(index + 1));
  // The first history page ends at a run started at the oldest loaded message. The report is
  // older, has no turn/reply key, and answers that loaded question; the strict timestamp cutoff
  // must not discard it.
  const allRuns = [
    run(1, "m1", 0),
    run(2, "m2", 1),
    ...Array.from({ length: 19 }, (_, index) => run(index + 3, `m${index + 3}`, index + 2)),
  ];
  const fake = client(all, allRuns);
  const store = new HomeChannelsStore(fake.api as never);
  const stop = store.subscribe(() => {});
  await store.start();
  await waitForReport(store);
  expect(fake.calls.filter((call) => call.op === HomeOps.runs).some((call) => Array.isArray(call.params.answers))).toBe(
    true,
  );
  expect(store.runs.get("chief-conv", "chief", "r1")?.steps[0]?.text).toBe("[a1] report");
  stop();
});

test("answer lookup keeps old silent reports bounded by current history", async () => {
  const all = Array.from({ length: 26 }, (_, index) => message(index + 1));
  const allRuns = [
    run(1, "m1", 0),
    ...Array.from({ length: 10_000 }, (_, index) => run(index + 2, "unrelated", index + 2)),
  ];
  const fake = client(all, allRuns);
  const store = new HomeChannelsStore(fake.api as never);
  const settled = trackRunLoads(store);
  const stop = store.subscribe(() => {});
  await store.start();
  await settled();
  await waitForReport(store);
  const runCalls = fake.calls.filter((call) => call.op === HomeOps.runs);
  expect(runCalls.some((call) => Array.isArray(call.params.answers))).toBe(true);
  expect(runCalls.length).toBeLessThanOrEqual(3);
  expect(store.runs.get("chief-conv", "chief", "r1")?.steps[0]?.text).toBe("[a1] report");
  stop();
});

test("loadOlder finds a silent run attached to the newly loaded question", async () => {
  const all = Array.from({ length: 130 }, (_, index) => message(index + 1));
  const allRuns = [run(1, "m1"), ...Array.from({ length: 25 }, (_, index) => run(index + 2, `m${index + 2}`))];
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
    // Rows from both agents share the first page's boundary. The adapter must return all of them
    // because the next owner cursor is strict and cannot ask for the remainder of a tie.
    agent_a: [raw("a3", "agent_a", 30), raw("a2", "agent_a", 30), raw("a1", "agent_a", 30), raw("a0", "agent_a", 20)],
    agent_b: [raw("b3", "agent_b", 30), raw("b2", "agent_b", 25), raw("b1", "agent_b", 15)],
  };
  const socket = {
    async request<T>(command: string, params: Record<string, unknown> = {}): Promise<T> {
      requests.push({ command, params });
      if (command === "identify") return { capabilities: ["cloud-conversation-runs-v1"] } as T;
      if (command !== "cloud-conversation-runs") return {} as T;
      const before = typeof params.before_started_at === "number" ? params.before_started_at : Number.MAX_SAFE_INTEGER;
      const runs = (byAgent[String(params.agent)] ?? []).filter((entry) => entry.started_at < before);
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
  expect(first.runs.map((entry) => entry.id)).toEqual(["a3", "a2", "a1", "b3"]);
  expect(first.hasMore).toBe(true);
  const firstCursor = Math.min(...first.runs.map((entry) => entry.startedAt));
  const second = await home.call<{ runs: Run[]; hasMore: boolean }>(HomeOps.runs, {
    conversation: "cloud-conv",
    limit: 2,
    beforeStartedAt: firstCursor,
  });
  expect(second.runs.map((entry) => entry.id)).toEqual(["b2", "a0"]);
  expect(
    requests
      .filter((request) => request.command === "cloud-conversation-runs")
      .every((request) => Number(request.params.limit) === 100),
  ).toBe(true);
  expect(
    requests
      .filter((request) => request.command === "cloud-conversation-runs")
      .every(
        (request) => request.params.before_started_at === undefined || request.params.before_started_at === firstCursor,
      ),
  ).toBe(true);
});

test("a legacy Cloud owner with a hard page cap cannot continue a timestamp tie", async () => {
  const raw = (id: string, started: number) => ({
    id,
    conversation: "cloud-ties",
    author: "agent_a",
    status: "done",
    started_at: started,
    updated_at: started,
    rev: 1,
    step_count: 0,
    answers: [],
  });
  const tieIds = Array.from({ length: 101 }, (_, index) => `tie-${index}`);
  const runs = [...tieIds.map((id) => raw(id, 30)), raw("older", 20)];
  const requests: Record<string, unknown>[] = [];
  const socket = {
    async request<T>(command: string, params: Record<string, unknown> = {}): Promise<T> {
      requests.push({ command, ...params });
      if (command === "identify") return { capabilities: ["cloud-conversation-runs-v1"] } as T;
      if (command !== "cloud-conversation-runs") return {} as T;
      const before = typeof params.before_started_at === "number" ? params.before_started_at : Number.MAX_SAFE_INTEGER;
      const available = runs.filter((entry) => entry.started_at < before);
      const limit = Number(params.limit);
      return { runs: available.slice(0, limit), has_more: available.length > limit } as T;
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
  cloud.known.add("cloud-ties");
  cloud.entries.set("cloud-ties", {
    conversation: "cloud-ties",
    kind: "group",
    title: "Cloud ties",
  });
  cloud.heads.set("cloud-ties", {
    id: "cloud-ties",
    participants: [{ id: "agent_a", kind: "agent", display_name: "A" }],
  });

  const first = await home.call<{ runs: Run[]; hasMore: boolean }>(HomeOps.runs, {
    conversation: "cloud-ties",
    limit: 2,
  });
  const cursor = Math.min(...first.runs.map((entry) => entry.startedAt));
  const second = await home.call<{ runs: Run[]; hasMore: boolean }>(HomeOps.runs, {
    conversation: "cloud-ties",
    limit: 2,
    beforeStartedAt: cursor,
  });
  // Simulate a pre-#28069 Cloud brain that truncated a timestamp tie at 100.
  // Its strict timestamp cursor cannot retrieve the omitted 101st row. Current Cloud
  // brains use readRunPage and return the *whole* boundary tie (covered below).
  expect(first.runs.filter((entry) => entry.startedAt === 30)).toHaveLength(100);
  expect(first.hasMore).toBe(true);
  expect(second.runs.map((entry) => entry.id)).toEqual(["older"]);
  expect(requests.some((request) => request.before_started_at === cursor)).toBe(true);
});

test("a tie-preserving Cloud owner hydrates 300 same-time runs before older history", async () => {
  const raw = (id: string, started: number) => ({
    id,
    conversation: "cloud-300",
    author: "agent_a",
    status: "done",
    started_at: started,
    updated_at: started,
    rev: 1,
    step_count: 0,
    answers: [],
  });
  const runs = [
    ...Array.from({ length: 300 }, (_, index) => raw(`report-${String(index).padStart(3, "0")}`, 30)),
    raw("older", 20),
  ];
  const requests: Record<string, unknown>[] = [];
  const socket = {
    async request<T>(command: string, params: Record<string, unknown> = {}): Promise<T> {
      requests.push({ command, ...params });
      if (command === "identify") return { capabilities: ["cloud-conversation-runs-v1"] } as T;
      if (command !== "cloud-conversation-runs") return {} as T;
      const before = typeof params.before_started_at === "number" ? params.before_started_at : Number.MAX_SAFE_INTEGER;
      const available = runs.filter((entry) => entry.started_at < before);
      const limit = Number(params.limit);
      const boundary = available[Math.min(limit, available.length) - 1]?.started_at;
      // Current Cloud contract (#28069): include the entire tie at the page limit.
      // Unlike a hard slice(0, 100), this permits a strict timestamp cursor.
      const page = boundary === undefined ? [] : available.filter((entry) => entry.started_at >= boundary);
      return { runs: page, has_more: available.length > page.length } as T;
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
  cloud.known.add("cloud-300");
  cloud.entries.set("cloud-300", { conversation: "cloud-300", kind: "group", title: "Cloud 300" });
  cloud.heads.set("cloud-300", {
    id: "cloud-300",
    participants: [{ id: "agent_a", kind: "agent", display_name: "A" }],
  });

  const first = await home.call<{ runs: Run[]; hasMore: boolean }>(HomeOps.runs, {
    conversation: "cloud-300",
    limit: 20,
  });
  const reports = first.runs.filter((entry) => entry.startedAt === 30);
  expect(reports).toHaveLength(300);
  expect(new Set(reports.map((entry) => entry.id)).size).toBe(300);
  expect(first.hasMore).toBe(true);
  expect(first.runs.some((entry) => entry.id === "older")).toBe(false);

  const cursor = Math.min(...first.runs.map((entry) => entry.startedAt));
  expect(cursor).toBe(30);
  const second = await home.call<{ runs: Run[]; hasMore: boolean }>(HomeOps.runs, {
    conversation: "cloud-300",
    limit: 20,
    beforeStartedAt: cursor,
  });
  expect(second.runs.map((entry) => entry.id)).toEqual(["older"]);
  expect(second.hasMore).toBe(false);
  expect(requests.filter((request) => request.command === "cloud-conversation-runs")
    .every((request) => request.limit === 100)).toBe(true);
  expect(requests.some((request) => request.before_started_at === 30)).toBe(true);
});

test("run step reads stay serial, cache complete runs, and stop cancels queued reads", async () => {
  const step = (runId: string) => ({
    id: `${runId}:step`,
    seq: 1,
    rev: 1,
    at: 2,
    kind: "note" as const,
    text: `${runId} report`,
    attachments: [],
    links: [],
  });
  const makeRun = (id: string): Run => ({
    id,
    conversation: "chief-conv",
    author: "chief",
    status: "done",
    startedAt: 1,
    updatedAt: 1,
    rev: 1,
    stepCount: 1,
    answers: [],
  });
  const deferred = () => {
    let resolve!: () => void;
    const promise = new Promise<void>((done) => {
      resolve = done;
    });
    return { promise, resolve };
  };
  const runReadClient = (firstRead: ReturnType<typeof deferred>) => {
    let runCalls = 0;
    let active = 0;
    let maximum = 0;
    const started = deferred();
    const api = {
      async call<R>(op: string, raw: unknown): Promise<R> {
        if (op !== HomeOps.run) {
          if (op === HomeOps.inbox) return { me, conversations: [], rev: 0 } as R;
          if (op === HomeOps.attachmentSupport) return { local: false, cloud: false } as R;
          return {} as R;
        }
        const params = (raw ?? {}) as Record<string, unknown>;
        runCalls += 1;
        active += 1;
        maximum = Math.max(maximum, active);
        if (runCalls === 1) started.resolve();
        try {
          if (runCalls === 1) await firstRead.promise;
          const run = makeRun(String(params.run));
          return { run, steps: [step(run.id)], hasMore: false } as R;
        } finally {
          active -= 1;
        }
      },
      async subscribe<E>(_stream: string, _onEvent: (data: E, seq: number) => void): Promise<() => void> {
        return () => {};
      },
      handle: () => () => {},
    };
    return {
      api,
      calls: () => ({ runCalls, maximum }),
      started: started.promise,
    };
  };

  const firstRead = deferred();
  const firstClient = runReadClient(firstRead);
  const store = new HomeChannelsStore(firstClient.api as never);
  const reads = [makeRun("run-a"), makeRun("run-b"), makeRun("run-c")].map((run) => store.loadRunSteps(run));
  await firstClient.started;
  expect(firstClient.calls()).toEqual({ runCalls: 1, maximum: 1 });
  firstRead.resolve();
  await Promise.all(reads);
  expect(firstClient.calls()).toEqual({ runCalls: 3, maximum: 1 });
  await store.loadRunSteps(makeRun("run-a"));
  expect(firstClient.calls()).toEqual({ runCalls: 3, maximum: 1 });

  const cancelledRead = deferred();
  const cancelledClient = runReadClient(cancelledRead);
  const cancelledStore = new HomeChannelsStore(cancelledClient.api as never);
  const unsubscribe = cancelledStore.subscribe(() => {});
  await cancelledStore.start();
  const existing = cancelledStore.loadRunSteps(makeRun("run-existing"));
  await cancelledClient.started;
  const queued = cancelledStore.loadRunSteps(makeRun("run-queued"));
  expect(cancelledClient.calls()).toEqual({ runCalls: 1, maximum: 1 });
  unsubscribe();
  // Reopening the same conversation queues a fresh read even while its old lifetime is draining.
  const reopenStop = cancelledStore.subscribe(() => {});
  await cancelledStore.start();
  const reopened = cancelledStore.loadRunSteps(makeRun("run-existing"));
  cancelledRead.resolve();
  await Promise.all([existing, queued, reopened]);
  expect(cancelledClient.calls()).toEqual({ runCalls: 2, maximum: 1 });
  expect(cancelledStore.runs.get("chief-conv", "chief", "run-existing")?.complete).toBe(true);
  expect(cancelledStore.runs.get("chief-conv", "chief", "run-queued")).toBeUndefined();
  reopenStop();
});

test("run step history reads past ten pages and stops on a nonadvancing cursor", async () => {
  const baseRun: Run = {
    id: "long-run",
    conversation: "chief-conv",
    author: "chief",
    status: "done",
    startedAt: 1,
    updatedAt: 1,
    rev: 1,
    stepCount: 11,
    answers: [],
  };
  const pageRequests: { afterRev: number; afterSeq: number }[] = [];
  const api = {
    async call<R>(op: string, raw: unknown): Promise<R> {
      if (op !== HomeOps.run) return {} as R;
      const params = (raw ?? {}) as Record<string, unknown>;
      const page = pageRequests.length + 1;
      pageRequests.push({ afterRev: Number(params.afterRev), afterSeq: Number(params.afterSeq) });
      const step = {
        id: `long-step-${page}`,
        seq: page,
        rev: page,
        at: page,
        kind: "note" as const,
        text: `step ${page}`,
        attachments: [],
        links: [],
      };
      return {
        run: { ...baseRun, rev: page },
        steps: [step],
        hasMore: page < 11,
      } as R;
    },
  };
  const store = new HomeChannelsStore(api as never);
  await store.loadRunSteps(baseRun);
  expect(pageRequests).toHaveLength(11);
  expect(pageRequests).toEqual(Array.from({ length: 11 }, (_, index) => ({ afterRev: index, afterSeq: index })));
  expect(store.runs.get("chief-conv", "chief", "long-run")).toMatchObject({
    complete: true,
    steps: expect.arrayContaining([expect.objectContaining({ id: "long-step-11" })]),
  });

  const stuckRequests: { afterRev: number; afterSeq: number }[] = [];
  const stuckRun: Run = { ...baseRun, id: "stuck-run", stepCount: 1 };
  let stuckRevision = 1;
  const stuckApi = {
    async call<R>(op: string, raw: unknown): Promise<R> {
      if (op !== HomeOps.run) return {} as R;
      const params = (raw ?? {}) as Record<string, unknown>;
      stuckRequests.push({ afterRev: Number(params.afterRev), afterSeq: Number(params.afterSeq) });
      return {
        run: { ...stuckRun, rev: stuckRevision },
        steps: [
          {
            id: "stuck-step",
            seq: 1,
            rev: stuckRevision,
            at: 1,
            kind: "note" as const,
            text: "stuck",
            attachments: [],
            links: [],
          },
        ],
        hasMore: true,
      } as R;
    },
  };
  const stuckStore = new HomeChannelsStore(stuckApi as never);
  await stuckStore.loadRunSteps(stuckRun);
  expect(stuckRequests).toEqual([
    { afterRev: 0, afterSeq: 0 },
    { afterRev: 1, afterSeq: 1 },
  ]);
  expect(stuckStore.runs.get("chief-conv", "chief", "stuck-run")?.complete).toBe(false);
  await stuckStore.loadRunSteps(stuckRun);
  expect(stuckRequests).toHaveLength(2);
  stuckRevision = 2;
  await stuckStore.loadRunSteps({ ...stuckRun, rev: stuckRevision });
  expect(stuckRequests).toHaveLength(4);
});

for (const { revision, timestamp, previousStatus } of [
  { revision: 0, timestamp: 5, previousStatus: "done" as const },
  { revision: 2, timestamp: 5, previousStatus: "done" as const },
  { revision: 0, timestamp: 0, previousStatus: "running" as const },
  { revision: 0, timestamp: 0, previousStatus: "done" as const },
]) {
  test(`reload refreshes unchanged-count report: rev ${revision}, time ${timestamp}, ${previousStatus} to done`, async () => {
    const latest = { ...run(1, "m1"), rev: revision, updatedAt: timestamp };
    const fake = client([message(1)], [latest]);
    const store = new HomeChannelsStore(fake.api as never);
    store.runs.setSteps(
      { ...latest, rev: revision === 0 ? 0 : 1, updatedAt: timestamp === 0 ? 0 : 2, status: previousStatus },
      [
        {
          id: "report:a1:1:0",
          seq: 1,
          rev: 1,
          at: 2,
          kind: "note",
          text: "old report",
          attachments: [],
          links: [],
        },
      ],
      true,
    );
    const stop = store.subscribe(() => {});
    try {
      await store.start();
      await waitForReport(store);
      expect(fake.calls.filter((call) => call.op === HomeOps.run)).toHaveLength(1);
      expect(store.runs.get("chief-conv", "chief", "r1")?.complete).toBe(true);
    } finally {
      stop();
    }
  });
}

test("Cloud history finds an old long run for a loaded reply after crossing the message cutoff", async () => {
  const reply = { ...message(130), clientMessageId: "old-turn" };
  const oldRun = { ...run(1, "outside-window"), turn: "old-turn" };
  const all = [...Array.from({ length: 29 }, (_, index) => message(101 + index)), reply];
  const allRuns = [oldRun, ...Array.from({ length: 25 }, (_, index) => run(50 + index, "outside-window"))];
  const fake = client(all, allRuns);
  const api = {
    ...fake.api,
    async call<R>(op: string, raw: unknown): Promise<R> {
      if (op === HomeOps.runs && (raw as { turns?: string[] })?.turns) return { runs: [], hasMore: false } as R;
      return fake.api.call<R>(op, raw);
    },
  };
  const store = new HomeChannelsStore(api as never);
  const stop = store.subscribe(() => {});
  try {
    await store.start();
    await waitForReport(store);
    expect(fake.calls.some((call) => call.op === HomeOps.runs && call.params.beforeStartedAt !== undefined)).toBe(true);
    expect(store.runs.forReply(reply)?.steps[0]?.text).toBe("[a1] report");
  } finally {
    stop();
  }
});

test("a failed unversioned read retries on a later history page but not repeated card loads", async () => {
  const all = Array.from({ length: 130 }, (_, index) => message(index + 1));
  const allRuns: Run[] = [];
  const fake = client(all, allRuns);
  let attempts = 0;
  const api = {
    ...fake.api,
    async call<R>(op: string, raw: unknown): Promise<R> {
      if (op === HomeOps.run && ++attempts === 1) throw new Error("temporary owner disconnect");
      return fake.api.call<R>(op, raw);
    },
  };
  const store = new HomeChannelsStore(api as never);
  const stop = store.subscribe(() => {});
  try {
    await store.start();
    const summary = { ...run(1, "m1"), rev: 0 };
    allRuns.push(summary);
    await store.loadRunSteps(summary);
    await store.loadRunSteps(summary);
    expect(attempts).toBe(1);
    await store.loadOlder();
    await waitForReport(store);
    expect(attempts).toBe(2);
  } finally {
    stop();
  }
});

test("answer lookup batches every message in a retained 300-message window", async () => {
  const all = Array.from({ length: 300 }, (_, index) => message(index + 1));
  const fake = client(all, [
    run(1, "m300", 0),
    ...Array.from({ length: 199 }, (_, index) => run(index + 2, "elsewhere", index + 2)),
  ]);
  const api = {
    ...fake.api,
    async call<R>(op: string, raw: unknown): Promise<R> {
      const result = await fake.api.call<R>(op, raw);
      return op === HomeOps.page ? { ...result, messages: all } : result;
    },
  };
  const store = new HomeChannelsStore(api as never);
  const settled = trackRunLoads(store);
  const stop = store.subscribe(() => {});
  try {
    await store.start();
    await settled();
    expect(
      fake.calls
        .filter((call) => Array.isArray(call.params.answers))
        .map((call) => (call.params.answers as string[]).length),
    ).toEqual([200, 100]);
    expect(store.runs.get("chief-conv", "chief", "r1")?.steps[0]?.text).toBe("[a1] report");
  } finally {
    stop();
  }
});

for (const field of ["turns", "answers"]) {
  test(`stopping Home during a ${field} lookup cancels hydration`, async () => {
    const fake = client([{ ...message(2), clientMessageId: "turn" }], [run(1, "m2")]);
    let release!: (value: unknown) => void;
    let started!: () => void;
    const pending = new Promise<unknown>((resolve) => {
      release = resolve;
    });
    const requested = new Promise<void>((resolve) => {
      started = resolve;
    });
    const api = {
      ...fake.api,
      async call<R>(op: string, raw: unknown): Promise<R> {
        if (op === HomeOps.runs && Array.isArray((raw as Record<string, unknown>)[field])) {
          started();
          return (await pending) as R;
        }
        return fake.api.call<R>(op, raw);
      },
    };
    const store = new HomeChannelsStore(api as never);
    const settled = trackRunLoads(store);
    const stop = store.subscribe(() => {});
    await store.start();
    await requested;
    stop();
    release({ runs: [run(1, "m2")], hasMore: false });
    await settled();
    expect(fake.calls.filter((call) => call.op === HomeOps.run)).toHaveLength(0);
    expect(store.runs.get("chief-conv", "chief", "r1")).toBeUndefined();
  });
}

test("a slow failing later history page does not hide messages already found", async () => {
  const reply = { ...message(130), clientMessageId: "unresolved" };
  const fake = client([message(129), reply], [run(1, "m129", 100)], false);
  let release!: () => void;
  let started!: () => void;
  const pending = new Promise<void>((resolve) => {
    release = resolve;
  });
  const requested = new Promise<void>((resolve) => {
    started = resolve;
  });
  const api = {
    ...fake.api,
    async call<R>(op: string, raw: unknown): Promise<R> {
      const params = raw as Record<string, unknown>;
      if (op === HomeOps.runs && !params.turns && !params.answers) {
        if (params.beforeStartedAt !== undefined) {
          started();
          await pending;
          throw new Error("owner disconnected");
        }
        return { runs: [run(1, "m129", 100)], hasMore: true } as R;
      }
      return fake.api.call<R>(op, raw);
    },
  };
  const store = new HomeChannelsStore(api as never);
  const settled = trackRunLoads(store);
  const stop = store.subscribe(() => {});
  try {
    await store.start();
    await requested;
    expect(store.runs.get("chief-conv", "chief", "r1")?.steps[0]?.text).toBe("[a1] report");
    release();
    await settled();
    expect(store.runs.get("chief-conv", "chief", "r1")?.steps[0]?.text).toBe("[a1] report");
  } finally {
    release();
    stop();
  }
});
