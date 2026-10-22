// l10n-allow-file: test fixture prompts, not shipped UI.
// A prompt that did not get there offers Retry only when Retry can work (Leo, 2026-10-21: Retry
// showed under a prompt held by the folder's open trust question, under one only the Mac app could
// approve, and under one the host does not accept, where it only failed again). The cause comes
// from the refusal's structured code and `data.reason`, never its text: a transient failure keeps
// Retry; a trust refusal offers it once the trust question is answered; a refusal that waits on a
// person at the Mac, or a request the host does not accept, never does. Edit, Remove and Details
// stay on every one.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { renderToStaticMarkup } from "react-dom/server";
import { DeliveryFailure } from "../src/agent-session/acpmux/conversation/PromptDelivery";
import { translate } from "../src/agent-session/acpmux/i18n";
import type { AcpmuxRow, PromptDelivery } from "../src/agent-session/acpmux/model";
import * as failureCause from "../src/agent-session/acpmux/promptFailureCause";

const failedRow = (delivery: Partial<PromptDelivery> & Record<string, unknown>): AcpmuxRow => ({
  id: "local-p1",
  version: 2,
  at: 0,
  kind: "user",
  text: "Ship it",
  failed: true,
  error: "Not sent.",
  delivery: {
    state: "failed",
    promptId: "p1",
    sessionId: "s",
    sentAt: 0,
    failedAt: 10,
    hop: "acpmux",
    ...delivery,
  } as PromptDelivery,
});

/// The failure line's buttons, by their text.
function buttons(row: AcpmuxRow, gate?: { trustBlocked: boolean; connected: boolean }): string[] {
  const props = { row, ...(gate ? { gate } : {}) } as Parameters<typeof DeliveryFailure>[0];
  const html = renderToStaticMarkup(<DeliveryFailure {...props} />);
  return [...html.matchAll(/<button[^>]*>([^<]*)<\/button>/g)].map((match) => match[1]!);
}

const RETRY = translate("turn.retry");
const OTHERS = [translate("message.edit"), translate("prompt.delivery.remove"), translate("prompt.delivery.details")];
const open = { trustBlocked: false, connected: true };

describe("Retry on a prompt that did not get there", () => {
  test("a send acpmux never answered keeps Retry", () => {
    expect(buttons(failedRow({ code: "timeout" }), open)).toEqual([RETRY, ...OTHERS]);
  });

  test("a refusal for want of a gesture keeps Retry: its click is the gesture", () => {
    expect(buttons(failedRow({ code: "transport.gesture_required" }), open)).toEqual([RETRY, ...OTHERS]);
  });

  test("a prompt held by the open trust question has no Retry until the question is answered", () => {
    const row = failedRow({ reason: "trust.pending", code: undefined });
    expect(buttons(row, { trustBlocked: true, connected: true })).toEqual(OTHERS);
    expect(buttons(row, { trustBlocked: false, connected: true })).toEqual([RETRY, ...OTHERS]);
  });

  test("a folder the person did not trust offers no Retry while it stays untrusted", () => {
    expect(buttons(failedRow({ reason: "trust.untrusted" }), { trustBlocked: true, connected: true })).toEqual(OTHERS);
  });

  test("a refusal only a person at the Mac can lift offers no Retry", () => {
    for (const code of ["transport.harness_not_confirmed", "transport.mode_not_confirmed", "transport.full_access_off"])
      expect(buttons(failedRow({ code }), open)).toEqual(OTHERS);
    for (const reason of ["remote.mode_not_asking", "trust.web_cannot_answer"])
      expect(buttons(failedRow({ reason }), open)).toEqual(OTHERS);
  });

  test("a request the host does not accept offers no Retry", () => {
    for (const code of ["transport.method_refused", "transport.intent_invalid", "transport.frame_too_large"])
      expect(buttons(failedRow({ code }), open)).toEqual(OTHERS);
  });

  test("acpmux's own retryable flag decides when it is there", () => {
    expect(buttons(failedRow({ reason: "peer_unreachable", retryable: true }), open)).toEqual([RETRY, ...OTHERS]);
    expect(buttons(failedRow({ reason: "launch.disabled", retryable: false }), open)).toEqual(OTHERS);
  });

  test("a send the pane's connection lost offers Retry once the pane is connected again", () => {
    for (const code of ["transport.stale_connection", "native.not_connected"]) {
      const row = failedRow({ hop: "connection", code });
      expect(buttons(row, { trustBlocked: false, connected: false })).toEqual(OTHERS);
      expect(buttons(row, open)).toEqual([RETRY, ...OTHERS]);
    }
  });

  test("an allow only the person at the Mac may give offers no Retry, connected or not", () => {
    // direct.ts labels every transport refusal but a gesture's as the connection's hop.
    expect(buttons(failedRow({ hop: "connection", code: "transport.person_required" }), open)).toEqual(OTHERS);
    expect(buttons(failedRow({ reason: "permission.person_required" }), open)).toEqual(OTHERS);
  });

  test("a refusal the pane does not know offers no Retry unless acpmux marks it retryable", () => {
    expect(buttons(failedRow({ hop: "connection", code: "transport.some_new_refusal" }), open)).toEqual(OTHERS);
    expect(buttons(failedRow({ reason: "session.some_new_refusal" }), open)).toEqual(OTHERS);
    expect(buttons(failedRow({ reason: "session.some_new_refusal", retryable: true }), open)).toEqual([
      RETRY,
      ...OTHERS,
    ]);
  });

  test("a turn that failed after acpmux took the prompt keeps Retry", () => {
    expect(buttons(failedRow({ hop: "agent" }), open)).toEqual([RETRY, ...OTHERS]);
    // Its reason is the turn's, not a refusal of the prompt.
    expect(buttons(failedRow({ hop: "agent", reason: "agent.exited" }), open)).toEqual([RETRY, ...OTHERS]);
  });

  test("a failed row with no record of its send (an older session's) offers no Retry: nothing is left to send", () => {
    const row: AcpmuxRow = { id: "local-p0", version: 1, at: 0, kind: "user", text: "Ship it", failed: true };
    expect(buttons(row, open)).toEqual([]);
  });
});

describe("the trust question's hold on Retry", () => {
  // What useFolderTrustAsk says while it reads the folder again after a trust.pending refusal.
  const holds = (trust: { blocked?: object; trusted: boolean }) => failureCause.trustHolds(trust);

  test("a read in flight holds: the answer is not known yet", () => {
    expect(holds({ blocked: {}, trusted: false })).toBe(true);
  });

  test("an open question or Don't trust holds", () => {
    expect(holds({ blocked: { reason: "trust.answerFirst" }, trusted: false })).toBe(true);
    expect(holds({ blocked: { reason: "trust.notTrustedNoPrompts" }, trusted: false })).toBe(true);
  });

  test("a read that came back with no answer holds: acpmux refuses the prompt again", () => {
    expect(holds({ blocked: undefined, trusted: false })).toBe(true);
  });

  test("only a folder known to be trusted lets Retry show", () => {
    expect(holds({ blocked: undefined, trusted: true })).toBe(false);
  });
});

// The client keeps the refusal's structured cause on the row's delivery, where the line reads it.
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

/// The delivery of a prompt the daemon refused with `data`, as acpmux writes it on the wire.
async function refusedDelivery(data: Record<string, unknown>): Promise<PromptDelivery | undefined> {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const { MockAcpmuxSocket, mockHost } = await import("../src/agent-session/acpmux/mock");
  class RefusingDaemon extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const self = this as unknown as { answer: (method: string, params: unknown) => Promise<unknown> };
      const answer = self.answer.bind(this);
      self.answer = (method, params) =>
        method === "session/prompt"
          ? Promise.reject(Object.assign(new Error(String(data.reason ?? "refused")), { data }))
          : answer(method, params);
    }
  }
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => undefined,
    undefined,
    () => new RefusingDaemon() as unknown as WebSocket,
  );
  try {
    await client.send("Ship it", [], "p-refused").catch(() => undefined);
    return client.promptDelivery("local-p-refused");
  } finally {
    client.close?.();
  }
}

describe("the refusal's cause on the delivery", () => {
  test("a trust refusal keeps its reason", async () => {
    const delivery = await refusedDelivery({ reason: "trust.pending", cwd: "/home/dev/x" });
    expect(delivery?.state).toBe("failed");
    expect(delivery?.reason).toBe("trust.pending");
  });

  test("a refusal acpmux marks retryable keeps the mark", async () => {
    const delivery = await refusedDelivery({ reason: "peer_unreachable", retryable: true });
    expect(delivery?.reason).toBe("peer_unreachable");
    expect(delivery?.retryable).toBe(true);
  });
});
