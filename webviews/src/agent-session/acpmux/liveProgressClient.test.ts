// l10n-allow-file: test fixture prompts, not shipped UI.
// Session Info's Progress reads the checklist the client publishes beside its rows (snapshot.progress,
// liveProgress.ts), not a scan of the rows. It must say what the transcript's plan card says: the
// chat's latest plan, live while its turn runs, ended once the turn stops or a later prompt comes in
// (ProgressSection `currentPlan`), and gone when the agent clears the list.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { AcpmuxSnapshot } from "./model";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  values: { window: scope.window, document: scope.document },
};

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

type Daemon = { record: (target: string, step: unknown, at?: number) => unknown };

const plan = (...steps: [string, "pending" | "in_progress" | "completed"][]) => ({
  update: {
    sessionUpdate: "plan",
    entries: steps.map(([content, status]) => ({ content, priority: "medium", status })),
  },
});
const say = (text: string) => ({ update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } });
const prompt = (text: string) => ({ mux: "user_message", msg: { text } });
const started = { mux: "turn_started", msg: {} };
const ended = { mux: "turn_result", msg: { status: "completed" } };

/// Replays `steps` into a client and returns its last snapshot once `done` holds for it.
async function snapshotAfter(steps: unknown[], done: (snapshot: AcpmuxSnapshot) => boolean) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  // A scripted socket starts empty; the normal fixture seeds unrelated history that would move
  // the attach-page boundary away from the current turn.
  const socket = new MockAcpmuxSocket(() => Promise.resolve(), { steps: [] });
  const daemon = socket as unknown as Daemon;
  for (const step of steps) daemon.record(mockHost.sessionId!, step);
  let last: AcpmuxSnapshot | undefined;
  const wakes: Array<() => void> = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      last = snapshot;
      for (const wake of wakes.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    while (!last || !done(last)) await new Promise<void>((resolve) => wakes.push(resolve));
    return last;
  } finally {
    client.close?.();
  }
}

const said = (text: string) => (snapshot: AcpmuxSnapshot) =>
  snapshot.rows.some((row) => row.kind === "assistant" && row.text?.includes(text));

test("a turn that ended keeps its plan in Progress, counted and ended", async () => {
  const snapshot = await snapshotAfter(
    [
      prompt("Build it"),
      started,
      plan(["Write", "in_progress"], ["Test", "pending"]),
      plan(["Write", "completed"], ["Test", "in_progress"]),
      say("Halfway."),
      ended,
    ],
    (next) => said("Halfway.")(next) && !next.isWorking,
  );
  expect(snapshot.progress?.plan.map((step) => step.status)).toEqual(["completed", "in_progress"]);
  expect(snapshot.progress?.completed).toBe(1);
  expect(snapshot.progress?.total).toBe(2);
  expect(snapshot.progress?.ended).toBe(true);
});

test("a later prompt leaves the plan in Progress, ended, until a new plan comes", async () => {
  const snapshot = await snapshotAfter(
    [
      prompt("Build it"),
      started,
      plan(["Write", "in_progress"]),
      ended,
      prompt("Now ship it"),
      started,
      say("Shipping."),
    ],
    said("Shipping."),
  );
  expect(snapshot.isWorking).toBe(true);
  expect(snapshot.progress?.plan.map((step) => step.content)).toEqual(["Write"]);
  expect(snapshot.progress?.ended).toBe(true);
});

test("a new plan in the running turn is live again", async () => {
  const snapshot = await snapshotAfter(
    [
      prompt("Build it"),
      started,
      plan(["Write", "completed"]),
      ended,
      prompt("More"),
      started,
      plan(["Ship", "in_progress"]),
      say("Going."),
    ],
    said("Going."),
  );
  expect(snapshot.progress?.plan.map((step) => step.content)).toEqual(["Ship"]);
  expect(snapshot.progress?.ended).toBeUndefined();
});

test("a cleared list takes Progress away", async () => {
  const snapshot = await snapshotAfter(
    [
      prompt("Build it"),
      started,
      plan(["Write", "in_progress"]),
      { update: { sessionUpdate: "plan", entries: [] } },
      say("Cleared."),
    ],
    said("Cleared."),
  );
  expect(snapshot.progress).toBeUndefined();
});

test("a list cleared after a later prompt takes Progress away", async () => {
  const snapshot = await snapshotAfter(
    [
      prompt("Build it"),
      started,
      plan(["Write", "completed"]),
      ended,
      prompt("Start over"),
      started,
      { update: { sessionUpdate: "plan", entries: [] } },
      say("Cleared."),
    ],
    said("Cleared."),
  );
  expect(snapshot.progress).toBeUndefined();
});

test("an explicitly cleared Progress section stays gone when older history loads", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve(), { steps: [] });
  const daemon = socket as unknown as Daemon;
  const record = (step: unknown) => daemon.record(mockHost.sessionId!, step);
  // Keep the historical plan outside the attach page. The current page starts at a turn boundary,
  // so loadOlder() takes the incremental foldOlder path that used to resurrect that plan.
  record(prompt("Older plan"));
  record(started);
  record(plan(["Old work", "completed"]));
  record(ended);
  // Keep enough turn-starting records after the historical plan to put it just beyond the attach
  // page while leaving the current clear in that page. The older read takes two pages and folds it.
  for (let index = 0; index < 600; index++) record(prompt(`history filler ${index}`));
  record(prompt("Current turn"));
  record(started);
  record(plan(["Current work", "in_progress"]));
  record({ update: { sessionUpdate: "plan", entries: [] } });
  record(say("Cleared."));

  let last: AcpmuxSnapshot | undefined;
  const wakes: Array<() => void> = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      last = snapshot;
      for (const wake of wakes.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    while (!last || !said("Cleared.")(last)) await new Promise<void>((resolve) => wakes.push(resolve));
    const current = last!;
    expect(current.progress).toBeUndefined();
    await client.loadOlder();
    expect(last!.rows.some((row) => row.plan?.some((step) => step.content === "Old work"))).toBe(true);
    expect(last!.progress).toBeUndefined();
  } finally {
    client.close?.();
  }
});

test("an active Progress plan survives an older historical clear", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve(), { steps: [] });
  const daemon = socket as unknown as Daemon;
  const record = (step: unknown) => daemon.record(mockHost.sessionId!, step);
  record(prompt("Older plan"));
  record(started);
  record(plan(["Old work", "completed"]));
  record({ update: { sessionUpdate: "plan", entries: [] } });
  record(ended);
  for (let index = 0; index < 600; index++) record(prompt(`history filler ${index}`));
  record(prompt("Current turn"));
  record(started);
  record(plan(["Current work", "in_progress"]));
  record(say("Current."));

  let last: AcpmuxSnapshot | undefined;
  const wakes: Array<() => void> = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      last = snapshot;
      for (const wake of wakes.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    while (!last || !said("Current.")(last)) await new Promise<void>((resolve) => wakes.push(resolve));
    expect(last!.progress?.plan.map((step) => step.content)).toEqual(["Current work"]);
    await client.loadOlder();
    expect(last!.rows.some((row) => row.plan?.some((step) => step.content === "Old work"))).toBe(true);
    expect(last!.progress?.plan.map((step) => step.content)).toEqual(["Current work"]);
  } finally {
    client.close?.();
  }
});

test("a turn the agent starts on its own leaves the ended plan ended", async () => {
  const snapshot = await snapshotAfter(
    [
      prompt("Build it"),
      started,
      plan(["Write", "in_progress"]),
      ended,
      { mux: "turn_started", msg: {} },
      say("Background."),
    ],
    (next) => said("Background.")(next) && next.isWorking,
  );
  expect(snapshot.progress?.plan.map((step) => step.content)).toEqual(["Write"]);
  expect(snapshot.progress?.ended).toBe(true);
});

test("Progress keeps its identity while the reply streams", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  const steps: unknown[] = [prompt("Build it"), started, plan(["Write", "in_progress"])];
  for (let token = 0; token < 20; token++) steps.push(say(`t${token} `));
  steps.push(say("end."));
  for (const step of steps) daemon.record(mockHost.sessionId!, step);
  const seen = new Set<object>();
  let finished = false;
  const wakes: Array<() => void> = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      if (snapshot.progress) seen.add(snapshot.progress);
      if (said("end.")(snapshot)) finished = true;
      for (const wake of wakes.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    while (!finished) await new Promise<void>((resolve) => wakes.push(resolve));
  } finally {
    client.close?.();
  }
  expect(seen.size).toBe(1);
});
