// l10n-allow-file: test fixture questions and answers, not shipped UI.
// A decided question read back from acpmux's `permission_decision` outcome (record.ts), per
// harness: the inverse of model.ts `reply`.
import { describe, expect, test } from "bun:test";
import { questionFromPermission, reply, summaryLines, type AgentQuestion, type Answer } from "./model";
import { answerFromOutcome, decidedQuestion } from "./record";

const options = [
  { optionId: "allow_once", name: "Answer", kind: "allow_once" },
  { optionId: "reject_once", name: "Reject", kind: "reject_once" },
];
const claude = questionFromPermission({
  permissionId: "p1",
  session: "s1",
  request: {
    toolCall: {
      toolCallId: "t1",
      rawInput: {
        questions: [
          {
            question: "Which auth method?",
            header: "Auth",
            multiSelect: false,
            options: [{ label: "OAuth 2.0" }, { label: "Keys, rotated" }],
          },
          {
            question: "Which platforms?",
            header: "Platforms",
            multiSelect: true,
            options: [{ label: "iOS" }, { label: "Android" }, { label: "Web" }],
          },
        ],
      },
      _meta: { claude: { tool: "AskUserQuestion" } },
    },
    options,
  },
})!;
const codex = questionFromPermission({
  permissionId: "p2",
  session: "s1",
  request: {
    toolCall: {
      toolCallId: "t2",
      rawInput: {
        questions: [{ id: "scope", question: "Which scope?", options: [{ label: "Repo" }, { label: "Org" }] }],
      },
      _meta: { codex: {} },
    },
    options,
  },
})!;
const acp = questionFromPermission({
  permissionId: "p3",
  session: "s1",
  request: {
    toolCall: { toolCallId: "t3", title: "Overwrite the file?", _meta: { acpmux: { interactive: true } } },
    options: [
      { optionId: "yes", name: "Overwrite", kind: "allow_once" },
      { optionId: "no", name: "Keep it", kind: "reject_once" },
    ],
  },
})!;

/// The outcome acpmux records for a reply (hub/permissions.rs `respond`).
const outcomeOf = (question: AgentQuestion, answer: Answer) => {
  const sent = reply(question, answer);
  return {
    outcome: "selected",
    optionId: sent.optionId,
    ...(sent.answers ? { _meta: { updatedInput: { answers: sent.answers } } } : {}),
  };
};
const lines = (question: AgentQuestion, outcome: unknown) => {
  const answer = answerFromOutcome(question, outcome);
  return answer && summaryLines(question, answer);
};

describe("answerFromOutcome", () => {
  test("Claude: a label with a comma stays one choice; several choices and Other text read back", () => {
    const answer: Answer = {
      selections: {
        q0: { optionIDs: ["Keys, rotated"] },
        q1: { optionIDs: ["iOS", "Web"], other: "watchOS" },
      },
    };
    expect(lines(claude, outcomeOf(claude, answer))).toEqual(["Auth: Keys, rotated", "Platforms: iOS, Web, watchOS"]);
  });

  test("Claude multi-select: a label with a comma among other choices reads back as options", () => {
    const multi = questionFromPermission({
      permissionId: "p4",
      session: "s1",
      request: {
        toolCall: {
          rawInput: {
            questions: [
              {
                question: "Which auth methods?",
                header: "Auth",
                multiSelect: true,
                options: [{ label: "OAuth" }, { label: "Keys, rotated" }, { label: "Keys" }],
              },
            ],
          },
          _meta: { claude: { tool: "AskUserQuestion" } },
        },
        options,
      },
    })!;
    const answer: Answer = { selections: { q0: { optionIDs: ["OAuth", "Keys, rotated"] } } };
    expect(answerFromOutcome(multi, outcomeOf(multi, answer))).toEqual(answer);
  });

  test("Claude single-select: Other text with a comma stays whole", () => {
    const answer: Answer = {
      selections: { q0: { optionIDs: [], other: "OAuth 2.0, with rotated keys" }, q1: { optionIDs: ["Web"] } },
    };
    expect(answerFromOutcome(claude, outcomeOf(claude, answer))).toEqual(answer);
  });

  test("the daemon's normalized question reads back as its harness's", () => {
    const normalized = questionFromPermission({
      permissionId: "p5",
      session: "s1",
      request: {
        toolCall: {
          rawInput: { questions: [{ question: "Which auth method?" }] },
          _meta: {
            acpmux: {
              question: {
                harness: "claude",
                agent: "Claude Code",
                items: [
                  {
                    id: "q0",
                    header: "Auth",
                    prompt: "Which auth method?",
                    options: [
                      { id: "OAuth 2.0", label: "OAuth 2.0" },
                      { id: "Keys", label: "Keys" },
                    ],
                    multiSelect: false,
                    allowsOther: true,
                  },
                ],
              },
            },
          },
        },
        options,
      },
    })!;
    const answer: Answer = { selections: { q0: { optionIDs: ["Keys"] } } };
    expect(lines(normalized, outcomeOf(normalized, answer))).toEqual(["Auth: Keys"]);
  });

  test("Codex: answers by question id", () => {
    const answer: Answer = { selections: { scope: { optionIDs: ["Org"] } } };
    expect(lines(codex, outcomeOf(codex, answer))).toEqual(["Which scope?: Org"]);
  });

  test("ACP: the permission option picked is the answer, the reject-kind one included", () => {
    expect(lines(acp, { outcome: "selected", optionId: "no" })).toEqual(["Overwrite the file?: Keep it"]);
  });

  test("cancelled, declined, or with no answers: not answered", () => {
    expect(decidedQuestion(claude, { outcome: "cancelled" }).state).toEqual({ kind: "cancelled" });
    expect(decidedQuestion(claude, { outcome: "selected", optionId: "reject_once" }).state).toEqual({
      kind: "cancelled",
    });
    expect(decidedQuestion(claude, { outcome: "selected", optionId: "allow_once" }).state).toEqual({
      kind: "cancelled",
    });
    expect(decidedQuestion(acp, { outcome: "selected", optionId: "gone" }).state).toEqual({ kind: "cancelled" });
    expect(decidedQuestion(codex, undefined).state).toEqual({ kind: "cancelled" });
  });

  test("a session above this one that answered is named; a person's answer names no one", () => {
    const outcome = { outcome: "selected", optionId: "no" };
    const bySession = decidedQuestion(acp, outcome, { session: "s-parent", name: "coordinator" });
    expect(bySession.state).toMatchObject({
      kind: "answered",
      answer: { respondent: { displayName: "coordinator", isRemote: false, isSession: true } },
    });
    const byDevice = decidedQuestion(acp, outcome, { device: "phone", feedItem: "f1" });
    expect(byDevice.state.kind === "answered" && byDevice.state.answer.respondent).toBe(undefined);
  });
});
