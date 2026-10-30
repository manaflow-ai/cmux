// A prompt that was not sent (no composer holds it: a New Tab ask, a seeded prompt, a queued one)
// keeps its bubble, says why it was not sent, and Retry sends it again (hq#2569 item 5). The
// parity audit drove the pane with posted clicks and keys, which the host never counts as the
// person's gesture: every send came back `transport.gesture_required`, and the bubble said only
// "Not sent. Press Retry to send it." with no reason, so Retry, refused the same way, looked dead.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

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

type Row = { id: string; kind: string; text?: string; failed?: boolean; error?: string; pending?: boolean };

/// The mock daemon behind the host relay: `refuse` decides, per session/prompt, the error the
/// relay or acpmux answers it with (undefined: it goes through).
async function paneWith(refuse: (attempt: number) => Error | undefined) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const prompts: string[] = [];
  class Relay extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const self = this as unknown as { answer: (method: string, params: Record<string, any>) => Promise<unknown> };
      const answer = self.answer.bind(this);
      self.answer = (method, params) => {
        if (method !== "session/prompt") return answer(method, params);
        prompts.push(String(params.prompt?.[0]?.text ?? ""));
        const refusal = refuse(prompts.length);
        return refusal ? Promise.reject(refusal) : answer(method, params);
      };
    }
  }
  let rows: Row[] = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => (rows = snapshot.rows as Row[]),
    undefined,
    () => new Relay() as unknown as WebSocket,
  );
  return { client, prompts, rows: () => rows };
}

const gestureRefusal = async () => {
  const { translate } = await import("./i18n");
  return Object.assign(new Error(translate("transport.gestureRequired")), { code: "transport.gesture_required" });
};

test("a prompt the host refused for want of a gesture says why beside its bubble", async () => {
  const refusal = await gestureRefusal();
  const pane = await paneWith(() => refusal);
  try {
    // A send no composer holds (a New Tab ask): the bubble stays, with Retry.
    await pane.client.send("ship it").catch(() => undefined);
    const bubble = pane.rows().find((row) => row.kind === "user" && row.text === "ship it");
    expect(bubble?.failed).toBe(true);
    // The reason, not a bare "Press Retry": the app did not see the person's own click or key.
    expect(bubble?.error).toBe("Not sent: it needs your own key press or click.");
  } finally {
    pane.client.close?.();
  }
});

test("a prompt the daemon refused shows the daemon's words beside its bubble", async () => {
  const pane = await paneWith(() => new Error("upstream request failed (502)"));
  try {
    await pane.client.send("ship it").catch(() => undefined);
    const bubble = pane.rows().find((row) => row.kind === "user" && row.text === "ship it");
    expect(bubble?.failed).toBe(true);
    expect(bubble?.error).toBe("Not sent: upstream request failed (502)");
  } finally {
    pane.client.close?.();
  }
});

test("Retry sends the same prompt again, and a sent one leaves no failed bubble", async () => {
  const refusal = await gestureRefusal();
  // The first send is refused; Retry (the person's own click) goes through.
  const pane = await paneWith((attempt) => (attempt === 1 ? refusal : undefined));
  try {
    await pane.client.send("ship it").catch(() => undefined);
    const failed = pane.rows().find((row) => row.kind === "user" && row.failed);
    expect(failed).toBeDefined();
    // The bubble's Retry button (conversation/PromptDelivery.tsx) runs `chat.retryPrompt` with its row id.
    await pane.client.retryPrompt(failed!.id);
    expect(pane.prompts).toEqual(["ship it", "ship it"]);
    // The mock chat's own seeded prompts stay; this prompt has one bubble.
    const users = pane.rows().filter((row) => row.kind === "user" && row.text === "ship it");
    expect(users).toHaveLength(1);
    expect(users.some((row) => row.failed)).toBe(false);
  } finally {
    pane.client.close?.();
  }
});

test("a Retry refused again says so, instead of drawing the same bubble back", async () => {
  const refusal = await gestureRefusal();
  const pane = await paneWith(() => refusal);
  try {
    await pane.client.send("ship it").catch(() => undefined);
    const first = pane.rows().find((row) => row.kind === "user" && row.failed);
    await pane.client.retryPrompt(first!.id).catch(() => undefined);
    expect(pane.prompts).toEqual(["ship it", "ship it"]);
    // The mock chat's own seeded prompts stay; this prompt has one bubble.
    const users = pane.rows().filter((row) => row.kind === "user" && row.text === "ship it");
    // One bubble, still failed, still with Retry: the second refusal is told apart from the first.
    expect(users).toHaveLength(1);
    expect(users[0]!.failed).toBe(true);
    expect(users[0]!.error).toBe("Still not sent: it needs your own key press or click.");
  } finally {
    pane.client.close?.();
  }
});

// Leo 2026-10-21: failed sends read "Not sent: trust.pending: answer the trust question for the
// folder first" and "Not sent: The pane sent a request the app does not accept." The bubble says
// one plain sentence chosen by acpmux's reason or the host's code; their words and code stay for
// Details.
test("a failed send says one plain sentence by its cause, and keeps the raw error and code for Details", async () => {
  const trustPending = Object.assign(new Error("trust.pending: answer the trust question for the folder first"), {
    data: { reason: "trust.pending", cwd: "/home/dev/parity-demo" },
  });
  const paneBug = Object.assign(new Error("The pane sent a request the app does not accept."), {
    code: "transport.intent_invalid",
  });
  const pane = await paneWith((attempt) => (attempt === 1 ? trustPending : paneBug));
  try {
    await pane.client.send("ship it").catch(() => undefined);
    await pane.client.send("and the tests").catch(() => undefined);
    const shown = (text: string) =>
      pane.rows().find((row) => row.kind === "user" && row.text === text) as
        | (Row & { delivery?: { reason?: string; code?: string; error?: string } })
        | undefined;
    const trust = shown("ship it");
    expect(trust?.failed).toBe(true);
    expect(trust?.error).toBe("Not sent until you trust this folder.");
    expect(trust?.delivery?.reason).toBe("trust.pending");
    expect(trust?.delivery?.error).toBe("trust.pending: answer the trust question for the folder first");
    const bug = shown("and the tests");
    expect(bug?.error).toBe("Not sent because of an error in the agent pane.");
    expect(bug?.delivery?.code).toBe("transport.intent_invalid");
    // No code in the words the bubble shows.
    for (const row of [trust, bug]) expect(row?.error).not.toMatch(/trust\.pending|transport\.|:\s*The /);
  } finally {
    pane.client.close?.();
  }
});

// The host spends one click's gesture on one session/prompt, so a card's Retry for several failed
// prompts sends them as one prompt: the texts in order, over the last one's bubble.
test("Retry on a run of failed prompts sends them again as one prompt", async () => {
  const pane = await paneWith((attempt) => (attempt <= 3 ? new Error("upstream request failed (502)") : undefined));
  try {
    for (const text of ["ship it", "and the tests", "open a PR"]) await pane.client.send(text).catch(() => undefined);
    const failed = pane.rows().filter((row) => row.kind === "user" && row.failed);
    expect(failed.map((row) => row.text)).toEqual(["ship it", "and the tests", "open a PR"]);
    await pane.client.retryPrompts(failed.map((row) => row.id));
    expect(pane.prompts).toEqual(["ship it", "and the tests", "open a PR", "ship it\n\nand the tests\n\nopen a PR"]);
    const users = pane.rows().filter((row) => row.kind === "user");
    expect(users.some((row) => row.failed)).toBe(false);
    expect(users.filter((row) => row.text === "ship it\n\nand the tests\n\nopen a PR")).toHaveLength(1);
    expect(users.some((row) => row.text === "and the tests")).toBe(false);
  } finally {
    pane.client.close?.();
  }
});

// #24144 review: a prompt refused with trust.pending keeps a Trust replay of its failed row. A chat
// switch (A, then B, back to A) clears the client's failed prompts with the rows; Trust in A must
// still send A's prompt, while a failed prompt the person removed stays gone.
test("Trust in a chat sends its trust-refused prompt even after a switch away and back", async () => {
  const { failedRowTrustRetry } = await import("./failedRowTrustRetry");
  const { MockAcpmuxSocket } = await import("./mock");
  const trustPending = () =>
    Object.assign(new Error("trust.pending: answer the trust question for the folder first"), {
      data: { reason: "trust.pending", cwd: "/home/dev/parity-demo" },
    });
  const pane = await paneWith((attempt) => (attempt <= 2 ? trustPending() : undefined));
  try {
    const client = pane.client;
    const home = client.selectedSession!;
    const other = MockAcpmuxSocket.live!.seedLoadSession(2);
    const replays: (() => void)[] = [];
    // Trust's replay sends without waiting (failedRowTrustRetry); the test waits for the sends it started.
    const started: Promise<unknown>[] = [];
    const track = <T>(send: Promise<T>) => (started.push(send), send);
    const settled = () => Promise.allSettled(started.splice(0));
    const rowRetry = failedRowTrustRetry({
      retry: (rowIds, ticket, anchor) => track(client.retryPrompts(rowIds, ticket, anchor)),
      runOf: (row) => [row],
      hold: () => undefined,
      takeTicket: () => undefined,
      copy: (rowIds) => client.failedPromptCopies(rowIds),
      restore: (copies) => client.restoreFailedPrompts(copies),
    });
    const route = (_error: unknown, again: () => void) => {
      replays.push(again);
      return true;
    };
    // Two refused prompts: one Trust replays, one the person removes before switching away.
    for (const text of ["ship it", "drop me"])
      await client.send(text).catch((error: unknown) => rowRetry.replayAfterTrust(error, route));
    expect(replays).toHaveLength(2);
    const dropped = pane.rows().find((row) => row.kind === "user" && row.text === "drop me");
    client.removeFailedPrompt(dropped!.id);
    await client.select(other);
    await client.select(home);
    expect(pane.rows().some((row) => row.failed)).toBe(false);
    // Trust: both replays run; only the prompt that was still failed goes, once.
    for (const again of replays) again();
    await settled();
    expect(pane.prompts).toEqual(["ship it", "drop me", "ship it"]);
    const users = pane.rows().filter((row) => row.kind === "user" && row.text === "ship it");
    expect(users).toHaveLength(1);
    expect(users[0]!.failed).not.toBe(true);
    // A second Trust replay of the same row sends nothing more.
    replays[0]!();
    await settled();
    expect(pane.prompts).toEqual(["ship it", "drop me", "ship it"]);
  } finally {
    pane.client.close?.();
  }
});

// #24144 review: the snapshot a held chat switch still shows takes Remove and Edit after the switch
// cleared the failed prompts. A prompt removed or taken back there is not brought back by Trust.
test("a failed prompt removed or edited after a switch cleared it stays gone after Trust", async () => {
  const { failedRowTrustRetry } = await import("./failedRowTrustRetry");
  const { MockAcpmuxSocket } = await import("./mock");
  const trustPending = () =>
    Object.assign(new Error("trust.pending: answer the trust question for the folder first"), {
      data: { reason: "trust.pending", cwd: "/home/dev/parity-demo" },
    });
  const pane = await paneWith((attempt) => (attempt <= 2 ? trustPending() : undefined));
  try {
    const client = pane.client;
    const home = client.selectedSession!;
    const other = MockAcpmuxSocket.live!.seedLoadSession(2);
    const replays: (() => void)[] = [];
    // Trust's replay sends without waiting (failedRowTrustRetry); the test waits for the sends it started.
    const started: Promise<unknown>[] = [];
    const track = <T>(send: Promise<T>) => (started.push(send), send);
    const settled = () => Promise.allSettled(started.splice(0));
    const rowRetry = failedRowTrustRetry({
      retry: (rowIds, ticket, anchor) => track(client.retryPrompts(rowIds, ticket, anchor)),
      runOf: (row) => [row],
      hold: () => undefined,
      takeTicket: () => undefined,
      copy: (rowIds) => client.failedPromptCopies(rowIds),
      restore: (copies) => client.restoreFailedPrompts(copies),
    });
    const route = (_error: unknown, again: () => void) => {
      replays.push(again);
      return true;
    };
    for (const text of ["remove me", "edit me"])
      await client.send(text).catch((error: unknown) => rowRetry.replayAfterTrust(error, route));
    const rowOf = (text: string) => pane.rows().find((row) => row.kind === "user" && row.text === text)!.id;
    const removed = rowOf("remove me");
    const edited = rowOf("edit me");
    await client.select(other);
    // The held snapshot's Remove and Edit land after the switch cleared the client's failed prompts.
    client.removeFailedPrompt(removed);
    client.takeFailedPrompt(edited);
    await client.select(home);
    for (const again of replays) again();
    await settled();
    expect(pane.prompts).toEqual(["remove me", "edit me"]);
  } finally {
    pane.client.close?.();
  }
});
