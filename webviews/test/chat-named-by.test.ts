// l10n-allow-file: test fixture chat names, not shipped UI.
// A tab that recorded a chat's name or its harness's own session id in place of acpmux's id
// (an agent opened it with `acpmux ls --json`'s first id, `agentSessionId`): the pane opens the one
// listed chat that goes by it, and says the session no longer exists when more than one does
// (chatUnavailable.ts `gone`), instead of "Reconnecting…" forever (Leo, 2026-11-05).
import { expect, test } from "bun:test";
import { chatNamedBy } from "../src/agent-session/acpmux/direct";

const lane = {
  sessionId: "01a18641-99db-7622-a8bc-496d43d639ca",
  name: "claude-sr2/cloud-demo",
  shortName: "cloud-demo",
  agentSessionId: "01a18641-9a05-7c33-8cfd-055af5d4f02a",
};
const other = { sessionId: "chat-other", name: "claude/other", agentSessionId: "harness-other" };

test("the harness's session id, the name or the short name names the chat", () => {
  for (const id of ["01a18641-9a05-7c33-8cfd-055af5d4f02a", "claude-sr2/cloud-demo", "cloud-demo"])
    expect(chatNamedBy(id, [other, lane])).toEqual({ session: lane.sessionId, ambiguous: false });
});

test("acpmux's own id, or an id nothing goes by, names nothing", () => {
  expect(chatNamedBy(lane.sessionId, [other, lane])).toEqual({ ambiguous: false });
  expect(chatNamedBy("01a1ffff-0000-7000-8000-000000000000", [other, lane])).toEqual({ ambiguous: false });
  expect(chatNamedBy("", [other, lane])).toEqual({ ambiguous: false });
});

test("a name more than one chat goes by is ambiguous, never an arbitrary pick", () => {
  const twin = { sessionId: "chat-twin", name: "codex/cloud-demo", shortName: "cloud-demo" };
  expect(chatNamedBy("cloud-demo", [lane, twin])).toEqual({ ambiguous: true });
  // Its harness id still names exactly one.
  expect(chatNamedBy(lane.agentSessionId, [lane, twin])).toEqual({ session: lane.sessionId, ambiguous: false });
});

test("a chat on another machine goes by its bare name too", () => {
  const remote = { sessionId: "chat-remote", name: "build-box/review", peer: "build-box" };
  expect(chatNamedBy("review", [remote])).toEqual({ session: "chat-remote", ambiguous: false });
});
