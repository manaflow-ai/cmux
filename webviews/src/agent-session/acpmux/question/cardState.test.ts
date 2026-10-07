import { expect, test } from "bun:test";
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import { cardState, highlightedRow, sendCard, type CardEffect, type CardInput, type CardState } from "./cardState";
import type { AgentQuestion } from "./model";

// The reducer tests mirror the Swift package's AgentQuestionCardStateTests on the same fixtures,
// so the Mac card and the agent tab answer keys the same way.
const FIXTURES = fileURLToPath(
  new URL("../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/", import.meta.url),
);
const fixture = (name: string): AgentQuestion => JSON.parse(fs.readFileSync(`${FIXTURES}${name}.json`, "utf8"));

/// A card driven like the Swift struct: `send` keeps the new state and returns the effect.
function card(name: string) {
  let state: CardState = cardState(fixture(name));
  return {
    send(input: CardInput): CardEffect {
      const next = sendCard(state, input);
      state = next.state;
      return next.effect;
    },
    get state() {
      return state;
    },
  };
}

const NONE: CardEffect = { type: "none" };
const submit = (selections: Record<string, { optionIDs: string[]; other?: string }>): CardEffect => ({
  type: "submit",
  answer: { selections },
});

test("a number key chooses and submits a single question", () => {
  const single = card("pending-single");
  expect(single.send({ type: "number", value: 3 })).toEqual(submit({ q0: { optionIDs: ["Passkeys"] } }));
});

test("arrows move the highlight and Enter chooses it", () => {
  const single = card("pending-single");
  expect(single.send({ type: "down" })).toEqual(NONE);
  expect(single.send({ type: "down" })).toEqual(NONE);
  expect(single.send({ type: "down" })).toEqual(NONE); // the Other row
  expect(single.send({ type: "down" })).toEqual(NONE); // clamps
  expect(highlightedRow(single.state)).toBe(3);
  expect(single.send({ type: "up" })).toEqual(NONE);
  expect(single.send({ type: "confirm" })).toEqual(submit({ q0: { optionIDs: ["Passkeys"] } }));
});

test("multi-select toggles and Enter submits", () => {
  const multi = card("pending-multi");
  expect(multi.send({ type: "number", value: 1 })).toEqual(NONE);
  expect(multi.send({ type: "number", value: 4 })).toEqual(NONE);
  expect(multi.send({ type: "number", value: 1 })).toEqual(NONE); // untoggles macOS
  expect(multi.send({ type: "number", value: 5 })).toEqual({ type: "beginOtherEditing" }); // the Other row
  expect(multi.state.editingOther).toBe(true);
  expect(multi.send({ type: "otherText", text: "visionOS" })).toEqual(NONE);
  expect(multi.send({ type: "confirm" })).toEqual(submit({ q0: { optionIDs: ["Web"], other: "visionOS" } }));
});

test("multi-select Enter with nothing chosen does not submit", () => {
  const multi = card("pending-multi");
  expect(multi.send({ type: "confirm" })).toEqual(NONE);
  expect(multi.send({ type: "submit" })).toEqual(NONE);
});

test("the Other row starts editing and its text answers a single select", () => {
  const fresh = card("pending-other-typing");
  expect(fresh.send({ type: "number", value: 4 })).toEqual({ type: "beginOtherEditing" });
  expect(fresh.send({ type: "otherText", text: "Mutual TLS" })).toEqual(NONE);
  expect(fresh.send({ type: "escape" })).toEqual(NONE); // leaves the field, keeps the draft
  expect(fresh.state.editingOther).toBe(false);
  expect(fresh.send({ type: "submit" })).toEqual(submit({ q0: { optionIDs: [], other: "Mutual TLS" } }));
});

test("several questions advance to the next unanswered one, then submit", () => {
  const four = card("pending-4-questions");
  expect(four.send({ type: "number", value: 2 })).toEqual(NONE);
  expect(four.state.activeItem).toBe(1);
  expect(four.send({ type: "number", value: 1 })).toEqual(NONE); // multi: toggle macOS
  expect(four.send({ type: "confirm" })).toEqual(NONE);
  expect(four.state.activeItem).toBe(2);
  expect(four.send({ type: "number", value: 1 })).toEqual(NONE);
  expect(four.state.activeItem).toBe(3);
  const effect = four.send({ type: "number", value: 1 });
  expect(effect.type).toBe("submit");
  if (effect.type !== "submit") return;
  expect(effect.answer.selections.q0?.optionIDs).toEqual(["API keys"]);
  expect(effect.answer.selections.q1?.optionIDs).toEqual(["macOS"]);
  expect(effect.answer.selections.q3?.optionIDs).toEqual(["Yes, off by default"]);
});

test("answered and cancelled cards ignore input, and Escape resigns", () => {
  for (const name of ["answered-collapsed", "cancelled"]) {
    const done = card(name);
    expect(done.send({ type: "number", value: 1 }), name).toEqual(NONE);
    expect(done.send({ type: "submit" }), name).toEqual(NONE);
    expect(done.send({ type: "escape" }), name).toEqual({ type: "resign" });
  }
});

test("Escape outside the Other field resigns without answering", () => {
  const single = card("pending-single");
  expect(single.send({ type: "escape" })).toEqual({ type: "resign" });
  expect(single.state.question.state.kind).toBe("pending");
});

test("out-of-range numbers do nothing", () => {
  const acp = card("acp-interactive"); // three options, no Other row
  expect(acp.send({ type: "number", value: 4 })).toEqual(NONE);
  expect(acp.send({ type: "number", value: 0 })).toEqual(NONE);
  expect(acp.send({ type: "click", row: 9 })).toEqual(NONE);
});

test("previous and next item move between questions and leave the Other field", () => {
  const four = card("pending-4-questions");
  expect(four.send({ type: "nextItem" })).toEqual(NONE);
  expect(four.state.activeItem).toBe(1);
  expect(four.send({ type: "nextItem" })).toEqual(NONE);
  expect(four.send({ type: "nextItem" })).toEqual(NONE);
  expect(four.send({ type: "nextItem" })).toEqual(NONE); // clamps
  expect(four.state.activeItem).toBe(3);
  expect(four.send({ type: "previousItem" })).toEqual(NONE);
  expect(four.state.activeItem).toBe(2);
});

test("sending never mutates the previous state", () => {
  const before = cardState(fixture("pending-multi"));
  const snapshot = JSON.stringify(before);
  sendCard(before, { type: "number", value: 1 });
  sendCard(before, { type: "otherText", text: "x" });
  expect(JSON.stringify(before)).toBe(snapshot);
});
