// The page half of the focus log (agent-session/acpmux/focusLossWatch.ts): a text input that loses
// the keyboard with no key or click is recorded with its cause and the focus route of the move.
import { describe, expect, test } from "bun:test";
import { Window } from "happy-dom";
import { lossCause, watchFocusLoss } from "../src/agent-session/acpmux/focusLossWatch";

describe("lossCause", () => {
  test("a removed input, a script call, a page that lost the keys, a plain move", () => {
    expect(lossCause({ connected: false, pageHasFocus: true, script: undefined, now: 0 })).toBe("removed");
    expect(
      lossCause({ connected: true, pageHasFocus: true, script: { op: "focus", on: "button", at: 990 }, now: 1000 }),
    ).toBe("script");
    expect(
      lossCause({ connected: true, pageHasFocus: false, script: { op: "focus", on: "button", at: 100 }, now: 1000 }),
    ).toBe("page");
    expect(lossCause({ connected: true, pageHasFocus: true, script: undefined, now: 1000 })).toBe("moved");
  });
});

describe("watchFocusLoss", () => {
  test("a script focus that takes the keys from the composer is recorded, unrouted", async () => {
    const window = new Window();
    const doc = window.document as unknown as Document;
    doc.body.innerHTML = `<textarea id="prompt"></textarea><button id="card">Allow</button>`;
    const prompt = doc.getElementById("prompt") as HTMLTextAreaElement;
    const card = doc.getElementById("card") as HTMLButtonElement;
    prompt.focus();
    const records: Record<string, string | number | boolean>[] = [];
    const stop = watchFocusLoss(
      window as unknown as Parameters<typeof watchFocusLoss>[0],
      (fields) => records.push(fields),
      () => 10_000,
    );
    card.focus();
    await Promise.resolve();
    stop();
    expect(records).toHaveLength(1);
    expect(records[0]).toMatchObject({
      cause: "script",
      what: "textarea",
      op: "focus",
      on: "button",
      route: "unrouted",
    });
  });
});
