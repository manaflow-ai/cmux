import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { afterDeleteDismiss } from "./deleteDismiss";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = { window: scope.window, document: scope.document };
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  for (const key of ["window", "document"] as const)
    if (saved[key] === undefined) delete scope[key];
    else scope[key] = saved[key];
  dom.window.close();
});

async function connected(hold?: Promise<void>) {
  const { AcpmuxDirectClient } = await import("../direct");
  const { MockAcpmuxSocket, mockHost } = await import("../mock");
  const purged: string[] = [];
  class RecordingHost extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const host = this as unknown as { answer: (method: string, params: Record<string, unknown>) => Promise<unknown> };
      const answer = host.answer.bind(this);
      host.answer = (method, params) => {
        if (method !== "_acpmux/kill") return answer(method, params);
        purged.push(String(params.sessionId));
        return (hold ?? Promise.resolve()).then(() => ({}));
      };
    }
  }
  const emitted: string[] = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      if (snapshot.sessionId) emitted.push(snapshot.sessionId);
    },
    undefined,
    () => new RecordingHost() as unknown as WebSocket,
  );
  return { client, purged, emitted };
}

test("a Delete confirmation painted for A cannot purge B after the hold releases before React commits", async () => {
  const { client, purged, emitted } = await connected();
  try {
    // Keep the confirmation's render snapshot on A while the listener has queued B's snapshot.
    const confirmed = client.selectedSession!;
    const replacement = await client.startSession("claude");
    expect(replacement).toBeDefined();
    expect(replacement).not.toBe(confirmed);
    await client.select(replacement!);
    expect(client.selectedSession).toBe(replacement);
    expect(emitted.at(-1)).toBe(replacement);
    const result = await Promise.allSettled([client.purge(confirmed)]);
    expect(purged).toEqual([]);
    expect(result[0]?.status).toBe("rejected");
  } finally {
    client.close();
  }
});

test("Delete dispatches the explicitly confirmed current session", async () => {
  const { client, purged } = await connected();
  try {
    const confirmed = client.selectedSession!;
    await client.purge(confirmed);
    expect(purged).toEqual([confirmed]);
  } finally {
    client.close();
  }
});

test("dismissing the Delete dialog while the purge is out keeps the deletion, so its tab still closes", async () => {
  let release!: () => void;
  const { client, purged } = await connected(new Promise<void>((resolve) => (release = resolve)));
  try {
    const confirmed = client.selectedSession!;
    const inFlight = { target: confirmed };
    // Before the purge is sent, a dismissal cancels the delete.
    expect(afterDeleteDismiss(inFlight, client.purgeInFlight)).toBeUndefined();
    const purging = client.purge(confirmed);
    await Promise.resolve();
    expect(purged).toEqual([confirmed]);
    expect(client.purgeInFlight).toBe(true);
    // Escape, an outside click or Close now leaves the deletion for its completion to close.
    expect(afterDeleteDismiss(inFlight, client.purgeInFlight)).toBe(inFlight);
    release();
    await purging;
    expect(client.purgeInFlight).toBe(false);
  } finally {
    client.close();
  }
});
