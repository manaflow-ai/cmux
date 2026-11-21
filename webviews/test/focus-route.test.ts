// The web half of the focus route (plans/cmux-next/focus-loss-AUDIT.md, "Focus route"): a move the
// person did not start (`system`) cannot take the keys from the text input they typed into within
// the last second; the person's own moves, and system moves while nobody types, still focus; every
// move is recorded with its origin and reason for the page's focus-loss records.
import { describe, expect, test } from "bun:test";
import { Window } from "happy-dom";
import {
  TYPING_GRACE_MS,
  focusRoute,
  lastFocusRoute,
  noteTypingForFocusRoute,
  refusesSystemMove,
} from "../src/ui/focusRoute";

function page() {
  const window = new Window();
  const doc = window.document as unknown as Document;
  doc.body.innerHTML = `<textarea id="prompt"></textarea><button id="card">Allow</button>`;
  const prompt = doc.getElementById("prompt") as HTMLTextAreaElement;
  const card = doc.getElementById("card") as HTMLButtonElement;
  prompt.focus();
  return { window, doc, prompt, card };
}

describe("focusRoute", () => {
  test("a system move leaves the text input the person types into", () => {
    const { doc, prompt, card } = page();
    noteTypingForFocusRoute(prompt);
    expect(focusRoute(card, "system", "a permission request")).toBe(false);
    expect(doc.activeElement).toBe(prompt);
    expect(lastFocusRoute(1000)).toMatchObject({ origin: "system", reason: "a permission request", refused: true });
  });

  test("the person's own move still focuses", () => {
    const { doc, prompt, card } = page();
    noteTypingForFocusRoute(prompt);
    expect(focusRoute(card, "person", "Tab to the card")).toBe(true);
    expect(doc.activeElement).toBe(card);
  });

  test("a system move focuses when nobody typed in the last second", () => {
    const { doc, prompt, card } = page();
    noteTypingForFocusRoute(prompt, performance.now() - TYPING_GRACE_MS - 50);
    expect(focusRoute(card, "system", "a permission request")).toBe(true);
    expect(doc.activeElement).toBe(card);
  });

  test("typing into another element does not guard this one", () => {
    const { prompt, card } = page();
    expect(refusesSystemMove(card, prompt, card, 0, 10)).toBe(false);
    expect(refusesSystemMove(card, prompt, prompt, 0, 10)).toBe(true);
    expect(refusesSystemMove(prompt, prompt, prompt, 0, 10)).toBe(false);
  });

  test("a handle with focus() is a target too", () => {
    const { prompt } = page();
    noteTypingForFocusRoute(null);
    let focused = 0;
    expect(focusRoute({ focus: () => void focused++ }, "system", "the composer handle")).toBe(true);
    expect(focused).toBe(1);
    expect(prompt).toBeTruthy();
  });
});
