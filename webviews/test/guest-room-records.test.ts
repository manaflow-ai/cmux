// l10n-allow-file: test fixtures.
// Exercise the room's JSON through the real fed transcript, not just a socket listener spy.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient, type EventRecord } from "../src/agent-session/acpmux/direct";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { ShareSocket, type ShareSocketLike } from "../src/agent-session/guest/shareSocket";

const say = (seq: number, text: string): EventRecord => ({
  seq,
  at: 1_000 + seq,
  dir: "in",
  kind: "agent_message_chunk",
  msg: {
    method: "session/update",
    params: { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  },
});

function room() {
  let shown: AcpmuxSnapshot | undefined;
  const client = AcpmuxDirectClient.fed("guest-chat", (next) => (shown = next));
  const sent: unknown[] = [];
  const socket: ShareSocketLike = {
    onopen: null,
    onmessage: null,
    onclose: null,
    send: (data) => void sent.push(JSON.parse(data)),
    close: () => undefined,
  };
  const transport = new ShareSocket(
    { url: "wss://room.test/guest", open: () => socket },
    {
      snapshot: (snapshot) => client.feed(snapshot.records, "snapshot"),
      records: (records) => client.feed(records, "live"),
      page: (records) => client.feed(records, "older"),
      presence: () => undefined,
      promptState: () => undefined,
      connection: () => undefined,
      ended: () => undefined,
    },
  );
  transport.connect();
  return {
    frame: (t: string, records: unknown[], fields: Record<string, unknown> = {}) =>
      socket.onmessage?.({ data: JSON.stringify({ v: 1, t, records, ...fields }) }),
    snapshot: () => shown,
    words: () => shown?.rows.map((row) => row.text ?? "").join("|"),
    older: () => transport.older(shown!.historyFrom!),
    sent,
    stop: () => {
      transport.stop();
      client.dispose();
    },
  };
}

for (const mode of ["snapshot", "records", "page"] as const)
  test(`${mode}: malformed room records cannot break the following transcript`, () => {
    const r = room();
    try {
      // Older-page records are below the initial snapshot; live records are above it.
      if (mode !== "snapshot") r.frame("snapshot", [say(mode === "page" ? 100 : 1, "Before. ")]);
      const base = say(2, "Malformed");
      const malformed: unknown[] = [
        null,
        [],
        { seq: 2 },
        { ...base, msg: undefined },
        { ...base, msg: null },
        { ...base, msg: [] },
        { ...base, msg: "message" },
        { ...base, dir: "unknown" },
        { ...base, kind: null },
        { ...base, at: "yesterday" },
        { ...base, seq: -1 },
        { ...base, seq: 2.5 },
        { ...base, seq: Number.MAX_SAFE_INTEGER + 1 },
        { ...base, msg: { method: "session/update", params: [] } },
        { ...base, msg: { method: "session/update", params: { update: "update" } } },
      ];
      expect(() => r.frame(mode, [...malformed, say(3, "After. ")])).not.toThrow();
      expect(r.words()).toContain("After.");
      expect(r.words()).not.toContain("Malformed");
      // A bad high sequence must not suppress a subsequent valid live record.
      r.frame("records", [say(101, "Still connected.")]);
      expect(r.words()).toContain("Still connected.");
    } finally {
      r.stop();
    }
  });

test("the relay's truncated records retain history cursors without entering the reducer as payloads", () => {
  const r = room();
  // This is exactly the relay's cut(record) shape: no msg or at, even for a mux record.
  const cut = (seq: number, dir = "in", kind = "agent_message_chunk") => ({
    seq,
    dir,
    kind,
    truncated: true,
    full_bytes: 300_000,
  });
  try {
    expect(() => r.frame("snapshot", [cut(10)], { watermark: 10, has_more: true })).not.toThrow();
    expect(r.snapshot()?.historyFrom).toBe(10);
    expect(r.older()).toBe(true);
    expect(r.sent).toEqual([{ v: 1, t: "older", before_seq: 10 }]);
    expect(() => r.frame("page", [cut(5, "mux", "permission_request")], { has_more: true })).not.toThrow();
    expect(r.snapshot()?.historyFrom).toBe(5);
    expect(r.snapshot()?.permission).toBeUndefined();
    expect(() => r.frame("records", [cut(11), say(12, "After cut.")])).not.toThrow();
    r.frame("records", [cut(11), say(12, "After cut.")]);
    expect(r.words()).toBe("After cut.");
  } finally {
    r.stop();
  }
});

for (const options of [{}, [null], ["allow"]])
  test(`malformed permission options ${JSON.stringify(options)} do not stop the guest transcript`, () => {
    const r = room();
    try {
      const malformed = {
        seq: 1,
        at: 1_001,
        dir: "mux",
        kind: "permission_request",
        msg: { permissionId: "ask", request: { title: "Run tests", options } },
      };
      expect(() => r.frame("snapshot", [malformed, say(2, "Still connected.")])).not.toThrow();
      expect(r.snapshot()?.permission).toBeUndefined();
      expect(r.words()).toContain("Still connected.");
    } finally {
      r.stop();
    }
  });
