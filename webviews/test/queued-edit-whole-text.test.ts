// A long queued prompt after a reload: acpmux's list gives a 200-character preview ending "…", and
// an edit opened from it would save the cut copy over the whole prompt. The pane reads the whole
// text of the person's cut rows (`_acpmux/queue_text`) and installs it only over the cut copy it was
// read for (direct/queue.ts `cutQueueRows`, `withWholeText`).
import { describe, expect, test } from "bun:test";
import { cutQueueRows, withWholeText } from "../src/agent-session/acpmux/direct/queue";
import type { QueuedPrompt } from "../src/agent-session/acpmux/model";

const whole = `${"a long queued prompt ".repeat(12)}\n\nthe last line that must not be lost`;
const cut = `${whole.replace(/\s+/g, " ").slice(0, 200)}…`;

describe("a queued prompt's whole text", () => {
  test("the person's cut rows are read, not whole ones, agents' messages or a teammate's", () => {
    const queue: QueuedPrompt[] = [
      { id: "cut", prompt: cut },
      { id: "short", prompt: "short" },
      { id: "agent", prompt: cut, message: { from: "other" } as never },
      { id: "teammate", prompt: cut, author: { id: "t" } as never },
    ];
    expect(cutQueueRows(queue).map((entry) => entry.id)).toEqual(["cut"]);
  });

  test("the whole text replaces the cut copy it was read for, and nothing else", () => {
    const queue: QueuedPrompt[] = [
      { id: "cut", prompt: cut },
      { id: "short", prompt: "short" },
    ];
    const next = withWholeText(queue, "cut", cut, whole);
    expect(next.map((entry) => entry.prompt)).toEqual([whole, "short"]);
    expect(cutQueueRows(next)).toEqual([]);
    // Edited (or its record read) meanwhile: the answer is stale and changes nothing.
    const edited: QueuedPrompt[] = [{ id: "cut", prompt: "edited since" }];
    expect(withWholeText(edited, "cut", cut, whole)).toBe(edited);
    // Gone, or an empty answer: unchanged.
    expect(withWholeText(queue, "gone", cut, whole)).toBe(queue);
    expect(withWholeText(queue, "cut", cut, "")).toBe(queue);
  });
});
