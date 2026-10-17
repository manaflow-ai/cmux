import { describe, expect, test } from "bun:test";
import { RunApiHttpError, RunBoardApiSession, createRunApiClient, normalizeRunSnapshot, type RunApiEvent, type RunApiSnapshot } from "./runApi";
import type { RunBoardSnapshot } from "./model";

const digest = "sha256:" + "a".repeat(64);
const run: RunApiSnapshot = {
  run: {
    id: "run-1",
    source: { repository: "manaflow-ai/cmux", commit: "b".repeat(40) },
    recipe: "parallel-review",
    desiredAttempts: 1,
    status: "running",
  },
  attempts: [{ id: "attempt-1", runId: "run-1", ordinal: 0, status: "running", providerVmId: "vm-1" }],
  artifacts: [],
};

const output: RunApiEvent = {
  id: "event-2",
  runId: "run-1",
  attemptId: "attempt-1",
  sequence: 2,
  attemptSequence: 1,
  kind: "attempt.output",
  payload: { text: "checking the workspace" },
};

const succeeded: RunApiEvent = {
  id: "event-3",
  runId: "run-1",
  attemptId: "attempt-1",
  sequence: 3,
  attemptSequence: 2,
  kind: "attempt.succeeded",
  payload: {},
};

describe("Run API client", () => {
  test("loads a snapshot before replaying events and maps API rows", async () => {
    const calls: string[] = [];
    const client = createRunApiClient({
      baseUrl: "https://cmux.test",
      fetch: async (input) => {
        const url = String(input);
        calls.push(url);
        if (url.endsWith("/events")) return new Response(JSON.stringify({ events: [output], nextCursor: null }), { status: 200 });
        return new Response(JSON.stringify(run), { status: 200 });
      },
    });
    const snapshot = await new RunBoardApiSession("run-1", client).snapshotAndReplay();
    expect(calls).toEqual(["https://cmux.test/api/runs/run-1", "https://cmux.test/api/runs/run-1/events"]);
    expect(snapshot.attempts[0]?.state).toBe("running");
    expect(snapshot.attempts[0]?.rows.at(-1)?.items?.[0]?.tool?.output).toBe("checking the workspace");
    expect(snapshot.cursor).toBe("2");
  });

  test("replays only events after the retained cursor and appends terminal state", async () => {
    const seen: Array<string | undefined> = [];
    const client = {
      getSnapshot: async () => run,
      getEvents: async (_runId: string, after?: string) => {
        seen.push(after);
        return after ? { events: [succeeded], nextCursor: null } : { events: [output], nextCursor: null };
      },
    };
    const session = new RunBoardApiSession("run-1", client);
    const first = await session.snapshotAndReplay();
    const second = await session.replay(first);
    expect(seen[0]).toBeUndefined();
    expect(seen[1]).toBeTruthy();
    expect(second.cursor).toBe("3");
    expect(second.attempts[0]?.state).toBe("completed");
  });

  test("refreshes from a fresh snapshot when the event cursor is stale", async () => {
    let snapshots = 0;
    let events = 0;
    const client = {
      getSnapshot: async () => {
        snapshots += 1;
        return snapshots === 1 ? run : { ...run, cursor: "4" };
      },
      getEvents: async () => {
        events += 1;
        if (events === 2) throw new RunApiHttpError(409, "cursor expired", "run_cursor_stale");
        return { events: events === 1 ? [output] : [succeeded], nextCursor: null };
      },
    };
    const session = new RunBoardApiSession("run-1", client);
    const first = await session.snapshotAndReplay();
    const recovered = await session.replay(first);
    expect(snapshots).toBe(2);
    expect(events).toBe(3);
    expect(recovered.attempts[0]?.state).toBe("completed");
  });

  test("normalizes a board fixture without treating it as a server snapshot", () => {
    const board: RunBoardSnapshot = { id: "run-1", title: "Fixture", intent: "intent", source: "fixture", cursor: "4", attempts: [] };
    expect(normalizeRunSnapshot(board)).toBe(board);
  });

  test("reports HTTP error codes for reconnect policy", async () => {
    const client = createRunApiClient({
      fetch: async () => new Response(JSON.stringify({ error: "run_cursor_stale", message: "expired" }), { status: 409 }),
    });
    await expect(client.getEvents("run-1", "stale")).rejects.toMatchObject({ status: 409, code: "run_cursor_stale" });
    await expect(client.getEvents("run-1", "stale")).rejects.toBeInstanceOf(RunApiHttpError);
  });

  test("maps artifact digests into verified evidence", () => {
    const snapshot = normalizeRunSnapshot({
      ...run,
      attempts: [{ ...run.attempts[0]!, status: "succeeded" }],
      artifacts: [
        { id: "artifact-1", attemptId: "attempt-1", name: "workspace.png", sizeBytes: 1, digest, uri: "artifact://one" },
      ],
    });
    expect(snapshot.attempts[0]?.artifacts[0]).toMatchObject({ kind: "screenshot", verified: true });
  });
});
