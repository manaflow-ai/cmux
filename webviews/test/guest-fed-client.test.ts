// l10n-allow-file: test fixtures.
// A client fed one chat's records from elsewhere (AcpmuxDirectClient.fed, the guest page's room):
// a snapshot draws the chat, live records past the newest held fold once, and an older page joins
// in front of what is held.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient, type EventRecord } from "../src/agent-session/acpmux/direct";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

const say = (seq: number, text: string): EventRecord => ({
  sessionId: "owner-session",
  seq,
  at: 1_000 + seq,
  dir: "in",
  kind: "agent_message_chunk",
  msg: {
    method: "session/update",
    params: { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  },
});
const prompt = (seq: number, text: string): EventRecord => ({
  seq,
  at: 1_000 + seq,
  dir: "mux",
  kind: "user_message",
  msg: { text },
});

test("a fed client folds a snapshot, live records once, and an older page in front", () => {
  let shown: AcpmuxSnapshot | undefined;
  const client = AcpmuxDirectClient.fed("guest-chat", (snapshot) => (shown = snapshot));
  const words = () => (shown?.rows ?? []).map((row) => row.text ?? "").join("|");
  client.feed([prompt(3, "Second ask"), say(4, "Working on it. ")], "snapshot");
  expect(words()).toContain("Second ask");
  expect(words()).toContain("Working on it.");
  // A copy of a held record, and the next one: only the new words fold.
  client.feed([say(4, "Working on it. "), say(5, "Done.")], "live");
  expect(words().match(/Working on it\./g)?.length).toBe(1);
  expect(words()).toContain("Done.");
  client.feed([prompt(1, "First ask"), say(2, "Sure.")], "older");
  const text = words();
  expect(text.indexOf("First ask")).toBeLessThan(text.indexOf("Second ask"));
  expect(text).toContain("Done.");
});
