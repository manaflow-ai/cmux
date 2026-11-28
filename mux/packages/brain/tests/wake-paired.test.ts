import { describe, expect, test } from "bun:test";
import { AGENT_MUX, type Message, type Participant, type Summary, USER_LOCAL } from "../src/core/conversation.ts";
import { wakes } from "../src/core/rules.ts";

// The paired-device rules of server-remote-conversations.md sections 5 and 6
// (D-C and the remote-origin gate), the same as cmux_chief::rules::wakes.

const person = (id: string, kind: Participant["kind"], extra: Partial<Participant> = {}): Participant => ({
  id,
  kind,
  display_name: id,
  ...extra,
});

const summary = (participants: Participant[]): Summary =>
  ({ id: "conv_a", owner: "local", title: "t", participants, last_seq: 0, rev: 0, created_at: "", updated_at: "", read_cursors: {} }) as Summary;

const message = (author: string, extra: Partial<Message> = {}): Message => ({
  id: "msg_x",
  conversation: "conv_a",
  seq: 1,
  client_msg_id: "k",
  author,
  parts: [{ type: "text", text: "hi" }],
  created_at: "",
  reactions: [],
  ...extra,
});

describe("wake rule with a paired device", () => {
  const paired = summary([
    person(USER_LOCAL, "human"),
    person(AGENT_MUX, "agent"),
    person("remote_inst_1", "human", { person: USER_LOCAL }),
  ]);

  test("a plain local message still wakes the mux (persons, not ids)", () => {
    expect(wakes(paired, message(USER_LOCAL), () => false)).toBe(true);
  });

  test("a device message the owner stamped as relayed from it wakes the mux (the remote-origin gate)", () => {
    expect(wakes(paired, message("remote_inst_1", { origin: { kind: "remote", install: "inst_1" } }), () => false)).toBe(true);
  });

  test("an unstamped device message never wakes the mux", () => {
    expect(wakes(paired, message("remote_inst_1"), () => false)).toBe(false);
  });

  test("a message stamped as relayed from another author never wakes the mux", () => {
    expect(wakes(paired, message(USER_LOCAL, { origin: { kind: "remote", install: "inst_1" } }), () => false)).toBe(false);
  });

  test("a second person still needs a mention", () => {
    const group = summary([...paired.participants, person("user_2", "human")]);
    expect(wakes(group, message(USER_LOCAL), () => false)).toBe(false);
  });
});
