// l10n-allow-file: test fixture prompts and replies, not shipped UI.
//
// A chat's kept tail holds its newest 400 messages, each message's streamed chunks counted once
// (tailCache.ts `keptEvents`), so a relaunch draws the chat's recent turns, not its last 400
// fragments (Leo, 2026-11-08, ask-cf7a62ebba). The host bounds a tail at 400 records, so the
// hand-over packs each message's chunks into one record and the page unpacks it on read. The pack
// must be lossless: a page reads back exactly the records it handed over, every chunk's seq and
// time included (#39431 review: a joined record that stood in for its chunks lost a thought's
// duration, a missed chunk's repair, a fork's check and the host's newest-seq comparison).
import { expect, test } from "bun:test";
import type { EventRecord } from "../src/agent-session/acpmux/direct";
import { KEPT_EVENTS, keptEvents, packStreamed, unpackStreamed } from "../src/agent-session/acpmux/tailCache";

const START = Date.UTC(2026, 10, 9, 9, 0, 0);
const SESSION = "0190a000-0000-7000-8000-00000000c0a2";

const record = (seq: number, kind: string, msg: Record<string, unknown>, dir = "in", at = START + seq * 1000) =>
  ({ sessionId: SESSION, seq, at, dir, kind, msg }) as EventRecord;
const chunk = (seq: number, text: string, messageId?: string, kind = "agent_message_chunk", at?: number) =>
  record(
    seq,
    kind,
    {
      method: "session/update",
      params: {
        sessionId: SESSION,
        update: { sessionUpdate: kind, content: { type: "text", text }, ...(messageId ? { messageId } : {}) },
      },
    },
    "in",
    at,
  );
const prompt = (seq: number, text: string) => record(seq, "user_message", { text }, "mux");

/// `turns` turns, each a prompt, 40 thinking chunks and a five-chunk reply.
function chat(turns: number): EventRecord[] {
  const out: EventRecord[] = [];
  let seq = 0;
  for (let turn = 1; turn <= turns; turn += 1) {
    out.push(prompt(++seq, `Question ${turn}`));
    for (let n = 0; n < 40; n += 1) out.push(chunk(++seq, `think ${n} `, undefined, "agent_thought_chunk"));
    for (const word of ["Answer ", `${turn} `, "is ", "in ", "place."]) out.push(chunk(++seq, word, `m-${turn}`));
  }
  return out;
}

test("packing a tail and unpacking it gives back every record as it was", () => {
  const events = chat(12);
  const packed = packStreamed(events);
  expect(packed.length).toBe(12 * 3);
  // Through JSON, as the host keeps it.
  expect(unpackStreamed(JSON.parse(JSON.stringify(packed)))).toEqual(events);
});

test("a thought's chunk times survive the pack, so its duration is drawn as before", () => {
  const events = [
    prompt(1, "Go"),
    chunk(2, "first ", undefined, "agent_thought_chunk", START + 1_000),
    chunk(3, "last", undefined, "agent_thought_chunk", START + 13_000),
  ];
  const back = unpackStreamed(packStreamed(events));
  expect(back[2]!.at - back[1]!.at).toBe(12_000);
  expect(back).toEqual(events);
});

test("a packed message carries its last chunk's seq, which is what the host compares tails by", () => {
  const packed = packStreamed([prompt(1, "Go"), chunk(2, "A", "m"), chunk(3, "B", "m"), chunk(4, "C", "m")]);
  expect(Math.max(...packed.map((event) => event.seq))).toBe(4);
});

test("a packed record whose chunks do not add up to its text is dropped, not drawn wrong", () => {
  const packed = packStreamed([prompt(1, "Go"), chunk(2, "A", "m"), chunk(3, "B", "m")]) as (EventRecord & {
    chunks?: [number, number, number][];
  })[];
  packed[1]!.chunks![0]![2] = 5;
  expect(unpackStreamed(packed)).toEqual([prompt(1, "Go")]);
});

test("a tail keeps the newest 400 messages, not the newest 400 fragments, and never cuts a message", () => {
  const events = chat(150);
  const kept = keptEvents(events);
  expect(packStreamed(kept).length).toBe(KEPT_EVENTS);
  // It starts at a message's first record: of 450 messages, the newest 400 start at turn 17's reply,
  // right after that turn's thinking.
  const first = kept[0]!;
  expect(first.kind).toBe("agent_message_chunk");
  expect(first.msg.params.update.content.text).toBe("Answer ");
  expect(events[events.indexOf(first) - 1]!.kind).toBe("agent_thought_chunk");
  // Far more than 400 records: about 133 turns of 47 records each.
  expect(kept.length).toBeGreaterThan(KEPT_EVENTS * 10);
});
