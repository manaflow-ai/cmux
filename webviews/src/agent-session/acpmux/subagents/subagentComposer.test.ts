// l10n-allow-file: test fixture prompts, not shipped UI.
// A subagent's composer never loses a prompt (review of #33280): a failed send comes back whole and
// apart from what was typed since, and a draft outlives leaving the subagent's pane.
import { describe, expect, test } from "bun:test";
import type { ComposerAttachment } from "../attachments";
import { afterFailedSend } from "./SubagentComposer";

const chip = (id: string, text: string) => ({ id, kind: "pasted", text }) as unknown as ComposerAttachment;

describe("afterFailedSend", () => {
  test("into an empty prompt the message comes back as typed, chips and all", () => {
    const held = [chip("p1", "a long paste")];
    expect(
      afterFailedSend({ text: "", attachments: [] }, { typed: "see [p1]", held, message: "see a long paste" }),
    ).toEqual({
      text: "see [p1]",
      attachments: held,
    });
  });

  test("over a newer draft the failed message goes above it whole, and the newer chips stay its own", () => {
    const newer = [chip("p2", "B's paste")];
    const next = afterFailedSend(
      { text: "B", attachments: newer },
      { typed: "A [p1]", held: [chip("p1", "A's paste")], message: "A A's paste" },
    );
    expect(next).toEqual({ text: "A A's paste\n\nB", attachments: newer });
  });

  test("two failures in a row keep both messages", () => {
    const once = afterFailedSend({ text: "C", attachments: [] }, { typed: "B", held: [], message: "B" });
    const twice = afterFailedSend(once, { typed: "A", held: [], message: "A" });
    expect(twice.text).toBe("A\n\nB\n\nC");
  });
});
