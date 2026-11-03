import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { afterDeleteDismiss } from "./deleteDismiss";
import { deleteClosesTab } from "./archiveClose";

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
  let socket: RecordingHost | undefined;
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      if (snapshot.sessionId) emitted.push(snapshot.sessionId);
    },
    undefined,
    () => (socket = new RecordingHost()) as unknown as WebSocket,
  );
  /// acpmux's `purged` notification for `sessionId`, delivered on its own (after the purge's answer).
  const notifyPurged = (sessionId: string) =>
    (socket as unknown as { deliver: (message: unknown) => void }).deliver({
      jsonrpc: "2.0",
      method: "_acpmux/session_changed",
      params: { kind: "purged", session: { sessionId } },
    });
  return { client, purged, emitted, notifyPurged };
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

test("a purged notification after the purge's answer selects nothing, so Delete's tab close stands", async () => {
  const { client, purged, notifyPurged } = await connected();
  try {
    const confirmed = client.selectedSession!;
    const other = await client.startSession("claude");
    await client.select(confirmed);
    expect(other).toBeDefined();
    await client.purge(confirmed);
    expect(purged).toEqual([confirmed]);
    expect(client.selectedSession).toBe(confirmed);
    notifyPurged(confirmed);
    await new Promise((resolve) => setTimeout(resolve, 0));
    // Not the fallback chat: the deleted chat's tab closes, it does not show another chat.
    expect(client.selectedSession).toBeUndefined();
  } finally {
    client.close();
  }
});

test("leaving the chat for an empty selection while the purge is out is not the purge's completion", async () => {
  let release!: () => void;
  const { client, notifyPurged } = await connected(new Promise<void>((resolve) => (release = resolve)));
  try {
    const confirmed = client.selectedSession!;
    const purging = client.purge(confirmed);
    await Promise.resolve();
    // The person opens a New Tab (or switches harness) in the pane: nothing is selected.
    client.leave();
    release();
    await purging;
    notifyPurged(confirmed);
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(client.selectedSession).toBeUndefined();
    expect(deleteClosesTab(client, confirmed)).toBe(false);
  } finally {
    client.close();
  }
});

test("the purge's own completion closes: still selected, or the client fell back from it", async () => {
  const { client, notifyPurged } = await connected();
  try {
    const confirmed = client.selectedSession!;
    await client.purge(confirmed);
    expect(deleteClosesTab(client, confirmed)).toBe(true);
    notifyPurged(confirmed);
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(client.selectedSession).toBeUndefined();
    expect(deleteClosesTab(client, confirmed)).toBe(true);
  } finally {
    client.close();
  }
});
