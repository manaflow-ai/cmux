// A queued prompt acpmux refuses when its turn comes, and that this pane did not send (it waited
// in a chat moved here, or across a restart), must not just leave the queue: the chat says it was
// not sent, and why. Only a refusal that arrives live says so; one in the history the pane loads
// was said when it happened, so opening the chat again does not repeat it.
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
  // Put back exactly what was there: a global that was absent stays absent for later files.
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

const REASON = "this harness has no reviewed asking mode for a remote WebSocket connection";

type Daemon = {
  record: (target: string, step: unknown, at?: number) => unknown;
  emit: (target: string, step: unknown, at?: number) => void;
};

const refused = (promptId: string) => ({
  mux: "prompt_refused",
  msg: {
    promptId,
    turnId: `turn-${promptId}`,
    client: "other",
    error: REASON,
    data: { reason: "remote.mode_not_asking" },
  },
});

test("a live refusal of a prompt this pane did not send says why; one in the history does not", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { translate } = await import("./i18n");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  // Refused before the pane opened the chat: history.
  daemon.record(mockHost.sessionId!, refused("p-old"));
  let rows: { kind: string; text?: string }[] = [];
  // Each snapshot wakes the waits below: they wait for the pane, not for a time.
  const snapshots: Array<() => void> = [];
  const until = async (check: () => boolean) => {
    while (!check()) await new Promise<void>((resolve) => snapshots.push(resolve));
  };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      rows = snapshot.rows as typeof rows;
      for (const wake of snapshots.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  const notes = () => rows.filter((row) => row.kind === "notice").map((row) => row.text);
  const said = translate("queue.promptRefused", { reason: REASON });
  try {
    await until(() => rows.length > 0);
    expect(said).not.toBe("queue.promptRefused");
    expect(notes()).not.toContain(said);
    // Refused while the pane shows the chat: live.
    daemon.emit(mockHost.sessionId!, refused("p-new"));
    await until(() => notes().includes(said));
    expect(notes().filter((text) => text === said)).toHaveLength(1);
  } finally {
    client.close?.();
  }
});
