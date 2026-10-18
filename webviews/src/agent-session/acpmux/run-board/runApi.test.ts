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
  attempts: [{ id: "attempt-1", runId: "run-1", ordinal: 0, status: "running", providerVmId: "vm-1", variant: { id: "focus", label: "Focus", instruction: "Use a quiet canvas." } }],
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
    expect(snapshot.attempts[0]?.variant?.id).toBe("focus");
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

  test("normalizes the flat Cloud receipt and preserves event-backed progress", () => {
    const receipt = {
      id: "run-flat",
      status: "running",
      provider: "cloud-vm",
      requestDigest: digest,
      desiredAttempts: 1,
      source: { repository: "manaflow-ai/cmux", commit: "c".repeat(40) },
      recipe: "parallel-review",
      attempts: [{
        id: "attempt-flat",
        runId: "run-flat",
        ordinal: 0,
        status: "running",
        variant: { id: "focus", label: "Focus", instructionDigest: digest },
      }],
      events: [{ ...output, id: "event-flat", runId: "run-flat", attemptId: "attempt-flat" }],
    };
    const snapshot = normalizeRunSnapshot(receipt);
    expect(snapshot.id).toBe("run-flat");
    expect(snapshot.source).toContain("manaflow-ai/cmux");
    expect(snapshot.cursor).toBe("2");
    expect(snapshot.attempts[0]?.variant?.instruction).toContain("Instruction digest sha256:");
    const session = new RunBoardApiSession("run-flat", {
      getSnapshot: async () => receipt,
      getEvents: async () => ({ events: [], nextCursor: null }),
    });
    return session.snapshotAndReplay().then((replayed) => {
      expect(replayed.attempts[0]?.rows.at(-1)?.items?.[0]?.tool?.output).toBe("checking the workspace");
    });
  });

  test("normalizes a board fixture without treating it as a server snapshot", () => {
    const board: RunBoardSnapshot = { id: "run-1", title: "Fixture", intent: "intent", source: "fixture", cursor: "4", attempts: [] };
    expect(normalizeRunSnapshot(board)).toBe(board);
  });

  test("falls back to receipt events while the dedicated event route is unavailable", async () => {
    const calls: string[] = [];
    const client = createRunApiClient({
      baseUrl: "https://cmux.test",
      fetch: async (input) => {
        const url = new URL(String(input));
        calls.push(url.pathname + url.search);
        if (url.pathname.endsWith("/events")) return new Response(JSON.stringify({ error: "route_not_found" }), { status: 404 });
        return new Response(JSON.stringify({ ...run, events: [output, succeeded] }), { status: 200 });
      },
    });
    const first = await client.getEvents("run-1");
    expect(first.events.map((event) => event.sequence)).toEqual([2, 3]);
    const replay = await client.getEvents("run-1", "eyJzZXF1ZW5jZSI6Mn0");
    expect(replay.events.map((event) => event.sequence)).toEqual([3]);
    expect(calls).toEqual([
      "/api/runs/run-1/events",
      "/api/runs/run-1",
      "/api/runs/run-1/events?after=eyJzZXF1ZW5jZSI6Mn0",
      "/api/runs/run-1",
    ]);
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

  test("creates, redeems and promotes through the durable Run routes", async () => {
    const requests: Array<{ path: string; method: string; idempotency?: string; body?: string }> = [];
    const client = createRunApiClient({
      baseUrl: "https://cmux.test",
      fetch: async (input, init) => {
        const url = new URL(String(input));
        requests.push({ path: url.pathname, method: init?.method ?? "GET", idempotency: new Headers(init?.headers).get("idempotency-key") ?? undefined, body: typeof init?.body === "string" ? init.body : undefined });
        if (url.pathname === "/api/runs") return new Response(JSON.stringify({ id: "run-new", status: "queued", attempts: [] }), { status: 202 });
        if (url.pathname.endsWith("/attach-ticket")) return new Response(JSON.stringify({ ticket: "ticket", runId: "run-new", attemptId: "attempt-1", provider: "cloud-vm", providerVmId: "vm", providerWorkspaceId: "ws", providerTerminalId: "term", expiresAt: "2026-10-17T00:00:00.000Z", route: "wss://fixture/v1/link", transport: "cmux-remote" }), { status: 200 });
        return new Response(JSON.stringify({ id: "promotion", runId: "run-new", attemptId: "attempt-1", runtime: { id: "runtime-1" } }), { status: 200 });
      },
    });
    await client.createRun({ source: { repository: "manaflow-ai/cmux", commit: "a".repeat(40), setupManifestDigest: `sha256:${"b".repeat(64)}` }, recipe: "parallel-review", desiredAttempts: 2, variants: [
      { id: "overview", label: "Overview", instruction: "Lead with project cards." },
      { id: "focus", label: "Focus", instruction: "Lead with a quiet canvas." },
    ] }, "create-key");
    await client.mintAttachTicket("run-new", "attempt-1");
    await client.redeemAttachTicket("run-new", "attempt-1", "ticket");
    await client.promoteAttempt("run-new", "attempt-1", "promote-key");
    expect(requests.map((request) => request.path)).toEqual([
      "/api/runs",
      "/api/runs/run-new/attempts/attempt-1/attach-ticket",
      "/api/runs/run-new/attempts/attempt-1/attach-ticket",
      "/api/runs/run-new/attempts/attempt-1/promote",
    ]);
    expect(requests[0]?.idempotency).toBe("create-key");
    const wire = JSON.parse(requests[0]?.body ?? "{}") as Record<string, any>;
    expect(wire.schema).toBe("cmux.run/v1");
    expect(wire.operationId).toBe("create-key");
    expect(wire.recipe).toEqual({ id: "parallel-review", version: 1 });
    expect(wire.intent.digest).toMatch(/^sha256:[0-9a-f]{64}$/);
    expect(wire.variants.map((variant: Record<string, unknown>) => variant.instructionDigest)).toEqual([
      "sha256:2ce92d4f044067d0ce82d8197bc750b0aba820b46ac596776b19aa6fe07503fd",
      "sha256:30709e6b5fc02a39d78e81485de0ae4356ab4af843ea7c2d95af318c3b1976e5",
    ]);
    expect(wire.variants.every((variant: Record<string, unknown>) => !("instruction" in variant))).toBe(true);
    expect(requests[3]?.idempotency).toBe("promote-key");
  });
});
