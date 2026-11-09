// l10n-allow-file: test fixture prompts and replies, not shipped UI.
//
// A chat's kept tail joins each message's streamed chunks into one record (tailCache.ts
// `keptEvents`), so a relaunch draws the chat's recent turns, not its last 400 fragments (Leo,
// 2026-11-08, ask-cf7a62ebba). The joined record must never hide what acpmux holds:
//   - a page that holds the run's start replaces it with acpmux's chunks, so a chunk the tail
//     missed live comes back (review F1 on #39431);
//   - a fork drawn from joined rows is checked against acpmux's raw page of the fork, joined the
//     same way, so valid history is kept (review F2 on #39431), and a message that ran past the
//     fork point is left for acpmux.
import { expect, test } from "bun:test";
import { mergeEventRecords, type EventRecord } from "../src/agent-session/acpmux/direct";
import { forkHistoryTail, sameForkHistory } from "../src/agent-session/acpmux/forkTail";
import { keptEvents } from "../src/agent-session/acpmux/tailCache";

const START = Date.UTC(2026, 10, 9, 9, 0, 0);
const SESSION = "0190a000-0000-7000-8000-00000000c0a1";

const record = (seq: number, kind: string, msg: Record<string, unknown>, dir = "in"): EventRecord => ({
  sessionId: SESSION,
  seq,
  at: START + seq * 1000,
  dir,
  kind,
  msg,
});
const chunk = (seq: number, text: string, messageId = "m-1", kind = "agent_message_chunk") =>
  record(seq, kind, {
    method: "session/update",
    params: { sessionId: SESSION, update: { sessionUpdate: kind, content: { type: "text", text }, messageId } },
  });
const prompt = (seq: number, text: string) => record(seq, "user_message", { text }, "mux");
const replyText = (events: EventRecord[]) =>
  events
    .filter((event) => event.kind === "agent_message_chunk")
    .map((event) => event.msg.params.update.content.text)
    .join("");

test("a page holding a joined run's start replaces it, so a chunk the tail missed comes back", () => {
  // Read live with chunk 3 missed: the tail joins "A" and "C".
  const tail = keptEvents([prompt(1, "Go"), chunk(2, "A"), chunk(4, "C")]).events;
  expect(replyText(tail)).toBe("AC");
  // acpmux's page holds the whole message.
  const page = [prompt(1, "Go"), chunk(2, "A"), chunk(3, "B"), chunk(4, "C")];
  expect(replyText(mergeEventRecords(page, tail))).toBe("ABC");
  expect(replyText(mergeEventRecords(tail, page))).toBe("ABC");
});

test("a page that starts inside a joined run keeps the run once, without its chunks twice", () => {
  const tail = keptEvents([prompt(1, "Go"), chunk(2, "A"), chunk(3, "B"), chunk(4, "C")]).events;
  const merged = mergeEventRecords([chunk(3, "B"), chunk(4, "C"), chunk(5, "D", "m-2")], tail);
  expect(replyText(merged)).toBe("ABCD");
});

/// A parent of `turns` turns, each a prompt, 20 thinking chunks and a five-chunk reply.
function parent(turns: number): EventRecord[] {
  const out: EventRecord[] = [];
  let seq = 0;
  for (let turn = 1; turn <= turns; turn += 1) {
    out.push(prompt(++seq, `Question ${turn}`));
    for (let n = 0; n < 20; n += 1) out.push(chunk(++seq, `think ${n} `, `t-${turn}`, "agent_thought_chunk"));
    for (const word of ["Answer ", `${turn} `, "is ", "in ", "place."]) out.push(chunk(++seq, word, `m-${turn}`));
  }
  return out;
}

test("a fork drawn from joined rows is kept when acpmux's raw page holds the same history", () => {
  const raw = parent(30);
  const forkSeq = raw.at(-1)!.seq;
  const drawn = keptEvents(raw).events;
  const tail = forkHistoryTail(
    { events: drawn, historyExhausted: true, turnOpener: undefined },
    { sessionId: "fork", forkSeq, lastSeq: forkSeq + 1, createdAt: START },
  );
  expect(tail?.events.filter((event) => event.kind === "user_message").length).toBe(30);
  // acpmux's newest page of the fork: 400 raw records of the same history.
  expect(sameForkHistory(raw.slice(-400), tail!.events, forkSeq)).toBe(true);
  // A page whose history differs is still refused.
  const changed = raw
    .slice(-400)
    .map((event) => (event.seq === forkSeq - 1 ? chunk(event.seq, "other ", "m-30") : event));
  expect(sameForkHistory(changed, tail!.events, forkSeq)).toBe(false);
});

test("a joined message that ran past the fork point is left for acpmux", () => {
  const raw = parent(2);
  const forkSeq = raw.at(-1)!.seq - 2;
  const tail = forkHistoryTail(
    { events: keptEvents(raw).events, historyExhausted: true, turnOpener: undefined },
    { sessionId: "fork", forkSeq, lastSeq: forkSeq + 1, createdAt: START },
  );
  expect(tail?.events.every((event) => (event.coalescedThrough ?? event.seq) <= forkSeq)).toBe(true);
});
