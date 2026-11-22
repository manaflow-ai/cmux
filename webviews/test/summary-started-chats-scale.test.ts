// l10n-allow-file: synthetic chat titles are test data, not product text.
import { expect, test } from "bun:test";
import type { StartedSession } from "../src/agent-session/acpmux/started/startedSessions";
import type { SubsessionRow } from "../src/agent-session/acpmux/subagents/subsessions";
import { startedChatsOutsideSubsessions } from "../src/agent-session/acpmux/summary/startedChatsOutsideSubsessions";

const chat = (id: string): StartedSession => ({
  sessionId: id,
  title: id,
  state: "running",
  createdAt: 1,
});

test("the started-chat list excludes sub-sessions once without reordering the remaining chats", () => {
  const first = chat("a");
  const second = chat("b");
  const third = chat("c");
  const result = startedChatsOutsideSubsessions([first, second, third, second], [
    { sessionId: "b" },
    { sessionId: "not-a-started-chat" },
  ] satisfies Pick<SubsessionRow, "sessionId">[]);
  expect(result).toEqual([first, third]);
  expect(result[0]).toBe(first);
  expect(result[1]).toBe(third);
});

test("3,000 started chats and sub-sessions read each sub-session id only once", () => {
  const total = 3_000;
  let lookedUp = 0;
  const subsessions: Pick<SubsessionRow, "sessionId">[] = Array.from({ length: total }, (_, i) => ({
    get sessionId() {
      lookedUp += 1;
      return `chat-${i}`;
    },
  }));
  const started = Array.from({ length: total }, (_, i) => chat(`chat-${i}`));
  const extra = chat("other");
  const result = startedChatsOutsideSubsessions([...started, extra], subsessions);
  expect(result).toEqual([extra]);
  // The old nested .some read sub-session IDs millions of times for this fixture.
  expect(lookedUp).toBe(total);
});
