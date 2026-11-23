// l10n-allow-file: test fixture machine and chat names, not shipped UI.
// A received line's sender chip opens the sender by acpmux's record of who sent it (`sender`,
// prompt_provenance.rs), never by the line's text: a self-declared sender's text carries "(self-declared,
// unauthenticated)", and the chip asked acpmux for that whole text, so no chat ever matched (Leo,
// 2026-11-07, on clicking such a chip: "it just fundamentally doesn't load").
import { expect, test } from "bun:test";
import { inboxNotice, senderKey } from "../src/agent-session/acpmux/conversation/inboxNotice";

const shown = "gcp-codex-swarm-01/ask-3f0256c58a-3 (self-declared, unauthenticated)";
const label = "gcp-codex-swarm-01/ask-3f0256c58a-3";

test("a notice keeps who sent each message, as acpmux recorded it", () => {
  const notice = inboxNotice("New messages", {
    threads: [
      {
        threadId: `declared:${label}`,
        from: [shown],
        new: 1,
        sender: { session: null, authenticated: false, label, labelDeclared: true },
        messages: [
          { promptId: "p1", from: shown, text: "done", sender: { session: null, label, labelDeclared: true } },
        ],
      },
    ],
  })!;
  const thread = notice.threads[0]!;
  expect(thread.sender).toEqual({ label });
  expect(thread.messages![0]!.sender).toEqual({ label });
  expect(senderKey(thread.from[0]!, thread.sender)).toBe(label);
});

test("a sender acpmux proved is asked for by its chat's id; one with no record by its line's text", () => {
  expect(senderKey("lane-a", { session: "mux-lane-a", label: "lane-a" })).toBe("mux-lane-a");
  expect(senderKey(" lane-b ", undefined)).toBe("lane-b");
});
