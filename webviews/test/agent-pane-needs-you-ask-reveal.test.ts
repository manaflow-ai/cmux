// Ask about this for another chat's ask: the host hands the question to the pane that shows that
// chat as an `ask:` reveal (AgentPaneAskOpen.swift `askReveal`), and that pane starts the side chat.
import { expect, test } from "bun:test";
import { ASK_REVEAL, revealedAsk, runRevealedAsk } from "../src/agent-session/acpmux/needsYou/askReveal";
import { revealedMessage } from "../src/agent-session/acpmux/links";

test("an ask reveal names its chat, turn and question; anything else is no ask", () => {
  const value = `${ASK_REVEAL}${JSON.stringify({ sessionId: "other", turnId: "t1", question: "What is going on here?" })}`;
  expect(revealedAsk(value)).toEqual({ sessionId: "other", turnId: "t1", question: "What is going on here?" });
  expect(revealedAsk(`${ASK_REVEAL}{"sessionId":"other","question":"Why?"}`)).toEqual({
    sessionId: "other",
    question: "Why?",
  });
  expect(revealedMessage(value)).toBeUndefined();
  for (const other of [
    "t1",
    "message:m1",
    "said:prompt:x",
    "ask:",
    "ask:{",
    'ask:{"sessionId":"a"}',
    'ask:{"question":"q"}',
    'ask:{"sessionId":"a","question":"  "}',
  ])
    expect(revealedAsk(other)).toBeUndefined();
});

test("the side chat starts once the pane shows the ask's chat, and never for another", async () => {
  const asked: string[] = [];
  const sideSession = async (sessionId: string, question: string) => void asked.push(`${sessionId}:${question}`);
  let shown: string | undefined;
  // The pane has looked a few times and not yet shown the chat: nothing is asked.
  let looks = 0;
  let looked: () => void = () => undefined;
  const lookedThrice = new Promise<void>((resolve) => (looked = resolve));
  const pending = runRevealedAsk(
    { sessionId: "other", question: "Why?" },
    {
      ready: (id) => {
        if (++looks === 3) looked();
        return shown === id;
      },
      sideSession,
      waitMs: 1000,
      stepMs: 5,
    },
  );
  await lookedThrice;
  expect(asked).toEqual([]);
  shown = "other";
  expect(await pending).toBe(true);
  expect(asked).toEqual(["other:Why?"]);
  asked.length = 0;
  shown = "elsewhere";
  expect(
    await runRevealedAsk(
      { sessionId: "other", question: "Why?" },
      { ready: (id) => shown === id, sideSession, waitMs: 30, stepMs: 5 },
    ),
  ).toBe(false);
  expect(asked).toEqual([]);
  await expect(
    runRevealedAsk(
      { sessionId: "other", question: "Why?" },
      { ready: () => true, sideSession: async () => Promise.reject(new Error("refused")) },
    ),
  ).rejects.toThrow("refused");
});
