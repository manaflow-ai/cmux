// Every send mode the composer has: each key, under each Follow-Up Messages mode, queueing on or
// off, an agent that steers or not, mid-turn or not. Leo, 2026-11-25: queuing and batching the
// person's messages is awkward, "we need to improve them"; this is the table of what each key does.
import { describe, expect, test } from "bun:test";
import { type FollowUpFacts, type FollowUpMode, followUpSteers, returnQueues, type SendKey } from "./followUpMode";

type Situation = { working: boolean; agentSteers: boolean; queueing: boolean };

/// The composer's facts for a draft with words in it (Composer.tsx, `followUp`).
function factsOf(s: Situation): FollowUpFacts {
  const steers = s.working && s.agentSteers;
  return { returnSteers: steers, steersAlways: steers && !s.queueing, steersUnseen: !s.working && s.agentSteers };
}

const KEYS: SendKey[] = ["return", "commandReturn", "menuQueue", "quickOpen"];
const MODES: FollowUpMode[] = ["steer", "queue"];
const bools = [false, true];
const situations: Situation[] = bools.flatMap((working) =>
  bools.flatMap((agentSteers) => bools.map((queueing) => ({ working, agentSteers, queueing }))),
);

/// What each key should do, written out case by case rather than from the code's expressions.
function expected(key: SendKey, mode: FollowUpMode, s: Situation): "steer" | "queue" {
  // An agent that cannot steer can only run a message after the turn.
  if (!s.agentSteers) return "queue";
  // No turn shows: a steer starts one, so nothing waits behind a turn the pane has not drawn.
  // ⌘Return and Send's menu only act mid-turn; idle they are Return.
  if (!s.working) return key === "return" || key === "quickOpen" ? "steer" : "queue";
  // Queueing off: nothing new waits, on any key.
  if (!s.queueing) return "steer";
  switch (key) {
    case "return":
      return mode === "steer" ? "steer" : "queue";
    case "commandReturn":
      return mode === "steer" ? "queue" : "steer";
    case "menuQueue":
    case "quickOpen":
      return "queue";
  }
}

describe("followUpSteers: every key in every send mode", () => {
  for (const key of KEYS)
    for (const mode of MODES)
      for (const s of situations)
        test(`${key} ${mode} ${JSON.stringify(s)}`, () => {
          if (!s.working && key !== "return" && key !== "quickOpen") return; // unreachable idle
          const steer = followUpSteers(key, mode, factsOf(s));
          expect(steer ? "steer" : "queue").toBe(expected(key, mode, s));
        });
});

test("Return and ⌘Return always do opposite things mid-turn while queueing is on", () => {
  for (const mode of MODES) {
    const f = factsOf({ working: true, agentSteers: true, queueing: true });
    expect(followUpSteers("return", mode, f)).toBe(!followUpSteers("commandReturn", mode, f));
  }
});

test("Follow-Up Messages on Queue holds Return only when Return would have steered", () => {
  for (const s of situations) {
    const f = factsOf(s);
    expect(returnQueues("queue", f)).toBe(s.working && s.agentSteers && s.queueing);
    expect(returnQueues("steer", f)).toBe(false);
  }
});

test("an empty draft with nothing staged does not steer on Return", () => {
  const f: FollowUpFacts = { returnSteers: false, steersAlways: false, steersUnseen: false };
  for (const mode of MODES) expect(followUpSteers("return", mode, f)).toBe(false);
});
