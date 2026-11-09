// l10n-allow-file: deterministic tripwire fixtures, not shipped UI.
// These are the three plan outcomes the pane must be able to replay: every check backed, one
// failed check, and a manifest whose checks have not run yet. The state decoder is deliberately
// tested at the event boundary, before React renders it.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { JSDOM } from "jsdom";
import { renderToStaticMarkup } from "react-dom/server";
import { NextStepCard } from "../conversation/NextStepCard";
import { TripwireStatus, type Tripwire } from "./TripwireStatus";
import { newerTripwires, readTripwires, type TripwireState } from "./state";

setDefaultTimeout(30_000);

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = { window: scope.window, document: scope.document };
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  scope.window = saved.window;
  scope.document = saved.document;
  dom.window.close();
});

function nextSnapshot(wakes: Array<() => void>, deadline: number): Promise<void> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      const index = wakes.indexOf(wake);
      if (index >= 0) wakes.splice(index, 1);
      reject(new Error("tripwire snapshot deadline exceeded"));
    }, Math.max(0, deadline - Date.now()));
    const wake = () => {
      clearTimeout(timeout);
      resolve();
    };
    wakes.push(wake);
  });
}

const green: Tripwire[] = [
  {
    name: "Wrong password shows an error",
    path: "tests/login.test.ts",
    verdict: "backed",
    toolCallId: "run-login",
    command: "bun test tests/login.test.ts",
  },
  {
    name: "Session expires",
    path: "tests/session.test.ts",
    verdict: "backed",
    toolCallId: "run-session",
    command: "bun test tests/session.test.ts",
  },
];
const red: Tripwire[] = [green[0]!, { ...green[1]!, verdict: "failed" }];
const neverRun: Tripwire[] = green.map(({ toolCallId: _toolCallId, command: _command, ...item }) => ({
  ...item,
  verdict: "none",
}));

const state = (revision: number, items: Tripwire[], turnId = "turn-1"): TripwireState => ({ revision, items, turnId });

test("all-green, one-red, and never-run fixtures retain their verdicts through replay", () => {
  const cases = [
    [state(1, green), ["backed", "backed"]],
    [state(2, red), ["backed", "failed"]],
    [state(3, neverRun), ["none", "none"]],
  ] as const;
  for (const [fixture, verdicts] of cases) {
    const decoded = readTripwires(fixture);
    expect(decoded?.items.map((item) => item.verdict)).toEqual(verdicts);
    expect(decoded?.turnId).toBe("turn-1");
  }
});

test("a late page of older history cannot turn the current red header green", () => {
  const current = state(8, red, "turn-8");
  const older = state(7, green, "turn-7");
  expect(newerTripwires(current, older)).toBe(current);
  expect(newerTripwires(current, older).items[1]!.verdict).toBe("failed");
  const next = state(9, neverRun, "turn-9");
  expect(newerTripwires(current, next)).toBe(next);
});

test("the event boundary rejects malformed or unbounded manifests", () => {
  expect(readTripwires(undefined)).toBeUndefined();
  expect(readTripwires({ revision: -1, items: [] })).toBeUndefined();
  expect(readTripwires({ revision: 1.5, items: [] })).toBeUndefined();
  expect(readTripwires({ revision: 1, items: [{ name: "x", path: "x", verdict: "maybe" }] })).toBeUndefined();
  expect(readTripwires({ revision: 1, items: [{ name: "x", path: "", verdict: "none" }] })).toBeUndefined();
  expect(
    readTripwires({
      revision: 1,
      items: Array.from({ length: 9 }, (_, index) => ({
        name: `check-${index}`,
        path: `tests/${index}.test.ts`,
        verdict: "none",
      })),
    }),
  ).toBeUndefined();
});

test("the header fixture draws all three states without changing the manifest", () => {
  const html = renderToStaticMarkup(<TripwireStatus items={red} />);
  expect(html).toContain('data-tripwire-total="2"');
  expect(html).toContain('data-tripwire-unresolved="1"');
  expect(html).toContain('data-tripwire-complete="false"');
  expect(html).toContain('data-tripwire-verdict="failed"');
  expect(html).toContain("Wrong password shows an error");
  expect(html).toContain("Session expires");
});

type Snapshot = { summary?: { tripwires?: TripwireState }; rows: Array<{ kind?: string; turnId?: string; tripwires?: TripwireState }> };

async function replayTurn(fixture: TripwireState, nextTurn?: TripwireState): Promise<Snapshot> {
  const { AcpmuxDirectClient } = await import("../direct");
  const { MockAcpmuxSocket, mockHost } = await import("../mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const turnId = fixture.turnId ?? `tripwire-${fixture.revision}`;
  const daemon = socket as unknown as { record: (target: string, step: unknown, at?: number) => unknown };
  daemon.record(mockHost.sessionId!, { mux: "user_message", msg: { text: "Run the tripwires" } });
  daemon.record(mockHost.sessionId!, { mux: "turn_started", msg: { turnId } });
  daemon.record(mockHost.sessionId!, {
    update: {
      sessionUpdate: "agent_message_chunk",
      messageId: `message-${turnId}`,
      content: { type: "text", text: "I wrote the checks first." },
    },
  });
  daemon.record(mockHost.sessionId!, { mux: "tripwires", msg: fixture });
  daemon.record(mockHost.sessionId!, { mux: "turn_end", msg: { turnId, stopReason: "end_turn" } });
  daemon.record(mockHost.sessionId!, { mux: "turn_result", msg: { status: "completed", turnId } });
  if (nextTurn) {
    daemon.record(mockHost.sessionId!, { mux: "user_message", msg: { text: "Make another change" } });
    daemon.record(mockHost.sessionId!, { mux: "turn_started", msg: { turnId: nextTurn.turnId } });
    daemon.record(mockHost.sessionId!, { mux: "tripwires", msg: nextTurn });
  }
  let latest: Snapshot | undefined;
  const wakes: Array<() => void> = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      latest = snapshot as unknown as Snapshot;
      for (const wake of wakes.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    const hasTurn = () => latest?.rows.some((row) => row.kind === "turnSummary" && row.turnId === turnId);
    const deadline = Date.now() + 10_000;
    while (!hasTurn() || (nextTurn && latest?.summary?.tripwires?.revision !== nextTurn.revision))
      await nextSnapshot(wakes, deadline);
    expect(hasTurn()).toBe(true);
    return latest!;
  } finally {
    client.close?.();
  }
}

test("mock daemon replay carries each fixture into both the header summary and its turn recap", async () => {
  for (const fixture of [state(21, green, "tripwire-green"), state(22, red, "tripwire-red"), state(23, neverRun, "tripwire-never")]) {
    const snapshot = await replayTurn(fixture);
    expect(snapshot.summary?.tripwires?.items.map((item) => item.verdict)).toEqual(
      fixture.items.map((item) => item.verdict),
    );
    const summary = snapshot.rows.find((row) => row.kind === "turnSummary" && row.turnId === fixture.turnId);
    expect(summary?.tripwires?.items.map((item) => item.verdict)).toEqual(
      fixture.items.map((item) => item.verdict),
    );
    const recap = renderToStaticMarkup(
      <NextStepCard ask={{ tag: "wrap_up", question: "", options: [], rest: "", recap: "Checks recorded.", tripwires: summary!.tripwires!.items }} />,
    );
    expect(recap).toContain("Checks recorded.");
    expect(recap.match(/data-tripwire-verdict=/g)?.length).toBe(fixture.items.length);
    expect(recap).toContain(`data-tripwire-unresolved="${fixture.items.filter((item) => item.verdict !== "backed").length}"`);
  }
});

test("a new turn clears the header's green verdicts while the previous recap retains its evidence", async () => {
  const finished = state(30, green, "tripwire-finished");
  const reset = state(31, neverRun, "tripwire-new");
  const snapshot = await replayTurn(finished, reset);
  expect(snapshot.summary?.tripwires).toEqual(reset);
  const previous = snapshot.rows.find((row) => row.kind === "turnSummary" && row.turnId === finished.turnId);
  expect(previous?.tripwires).toEqual(finished);
});

test("a replayed older mux event does not replace the current red header", async () => {
  const { AcpmuxDirectClient } = await import("../direct");
  const { MockAcpmuxSocket, mockHost } = await import("../mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as { record: (target: string, step: unknown, at?: number) => unknown };
  daemon.record(mockHost.sessionId!, { mux: "tripwires", msg: state(40, red, "tripwire-current") });
  daemon.record(mockHost.sessionId!, { mux: "tripwires", msg: state(39, green, "tripwire-old") });
  let latest: Snapshot | undefined;
  const wakes: Array<() => void> = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      latest = snapshot as unknown as Snapshot;
      for (const wake of wakes.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    const deadline = Date.now() + 10_000;
    while (latest?.summary?.tripwires?.revision !== 40) await nextSnapshot(wakes, deadline);
    expect(latest?.summary?.tripwires?.revision).toBe(40);
    expect(latest?.summary?.tripwires?.items[1]?.verdict).toBe("failed");
  } finally {
    client.close?.();
  }
});
