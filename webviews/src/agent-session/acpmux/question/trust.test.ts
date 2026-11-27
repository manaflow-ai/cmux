// l10n-allow-file: test fixture of the daemon's trust card, not shipped UI.
// The card the daemon raises when an agent wants a sub-session in a folder nobody answered the trust
// question for (cmux-tui/crates/acpmux/src/hub/trust_wait.rs): a choice question from cmux, answered
// by the picked permission option, and the sidebar tag that says the chat is waiting on it.
import { describe, expect, test } from "bun:test";
import { sessionEntry } from "../sessionList";
import { declineReply, questionFromPermission, reply } from "./model";

const request = {
  toolCall: {
    toolCallId: "trust-1",
    title: "Trust /Users/you/src/vendor-sdk?",
    _meta: {
      acpmux: {
        trust: { cwd: "/Users/you/src/vendor-sdk", name: "split-importer" },
        question: {
          harness: "acp",
          agent: "cmux",
          items: [
            {
              id: "q0",
              header: "Folder trust",
              prompt: "split-importer wants to work in /Users/you/src/vendor-sdk. Do you trust this folder?",
              options: [
                { id: "trust", label: "Trust folder", detail: "cmux stops asking about this folder." },
                { id: "not_now", label: "Not now" },
              ],
              multiSelect: false,
              allowsOther: false,
            },
          ],
        },
      },
    },
  },
  options: [
    { optionId: "trust", name: "Trust folder", kind: "allow_once" },
    { optionId: "not_now", name: "Not now", kind: "reject_once" },
  ],
};

describe("folder trust card", () => {
  const question = questionFromPermission({ permissionId: "p1", session: "s1", request })!;

  test("is a choice question from cmux", () => {
    expect(question.source.harness).toBe("acp");
    expect(question.source.agentName).toBe("cmux");
    expect(question.items[0]!.header).toBe("Folder trust");
    expect(question.items[0]!.options.map((option) => option.label)).toEqual(["Trust folder", "Not now"]);
  });

  test("Trust answers with the allow option and no answers", () => {
    const sent = reply(question, { selections: { q0: { optionIDs: ["trust"] } } });
    expect(sent).toEqual({ session: "s1", permissionId: "p1", optionId: "trust" });
  });

  test("Skip declines with the reject option, never an allow", () => {
    expect(declineReply(question)).toEqual({ session: "s1", permissionId: "p1", optionId: "not_now" });
  });
});

describe("a chat whose sub-session waits for trust", () => {
  test("carries the folder from the trust.pending tag", () => {
    const entry = sessionEntry({
      sessionId: "s1",
      status: "waiting",
      tags: { "trust.pending:split-importer": "/Users/you/src/vendor-sdk" },
    });
    expect(entry.trustPending).toBe("/Users/you/src/vendor-sdk");
  });

  test("has none without the tag", () => {
    expect(sessionEntry({ sessionId: "s1", status: "ready", tags: { pinned: "1" } }).trustPending).toBeUndefined();
  });
});
