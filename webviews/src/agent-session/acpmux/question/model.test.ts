import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import {
  declineReply,
  hasPreviews,
  QuestionProblemError,
  questionFromPermission,
  reply,
  replyParams,
  selection,
  summaryLines,
  type AgentQuestion,
  type Answer,
  type Problem,
} from "./model";

// The fixtures the Swift package tests read (Packages/Shared/CmuxAgentQuestion): one contract,
// two ports. `<name>.request.json` is the acpmux permission record, `<name>.json` the question.
const FIXTURES = fileURLToPath(
  new URL("../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/", import.meta.url),
);
const names = fs
  .readdirSync(FIXTURES)
  .filter((file) => file.endsWith(".json") && !file.endsWith(".request.json"))
  .map((file) => file.slice(0, -".json".length))
  .sort();
const readJSON = (file: string) => JSON.parse(fs.readFileSync(FIXTURES + file, "utf8"));
const expected = (name: string): AgentQuestion => readJSON(`${name}.json`);
const request = (name: string) => readJSON(`${name}.request.json`);

/// Compact JSON with sorted keys, like the Swift `AgentQuestionJSON.data()`.
function sortedJSON(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(sortedJSON).join(",")}]`;
  if (value && typeof value === "object")
    return `{${Object.keys(value)
      .filter((key) => (value as Record<string, unknown>)[key] !== undefined)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${sortedJSON((value as Record<string, unknown>)[key])}`)
      .join(",")}}`;
  return JSON.stringify(value);
}

const problemOf = (run: () => unknown): Problem | undefined => {
  try {
    run();
  } catch (error) {
    if (error instanceof QuestionProblemError) return error.problem;
    throw error;
  }
  return undefined;
};

describe("mapping", () => {
  test("every fixture maps to its expected question", () => {
    expect(names.length).toBeGreaterThanOrEqual(11);
    for (const name of names) {
      const question = expected(name);
      const mapped = questionFromPermission(request(name));
      expect(mapped, name).toBeDefined();
      // Answered and cancelled fixtures share a pending request: copy the recorded state.
      expect(sortedJSON({ ...mapped!, state: question.state }), name).toBe(sortedJSON(question));
    }
  });

  test("an ordinary tool permission is not a question", () => {
    const record = {
      permissionId: "p",
      session: "s",
      request: {
        toolCall: { toolCallId: "t1", title: "Bash ls", kind: "execute", rawInput: { command: "ls" } },
        options: [{ optionId: "allow_once", name: "Allow", kind: "allow_once" }],
      },
    };
    expect(questionFromPermission(record)).toBeUndefined();
  });

  test("a Claude question without usable items is not a question", () => {
    const record = {
      permissionId: "p",
      session: "s",
      request: {
        toolCall: {
          rawInput: { questions: [{ header: "No prompt" }] },
          _meta: { claude: { tool: "AskUserQuestion" } },
        },
        options: [{ optionId: "allow_once", name: "Answer", kind: "allow_once" }],
      },
    };
    expect(questionFromPermission(record)).toBeUndefined();
  });

  test("repeated option labels get unique ids", () => {
    const record = {
      permissionId: "p",
      session: "s",
      request: {
        toolCall: {
          rawInput: { questions: [{ question: "Pick", options: [{ label: "Same" }, { label: "Same" }] }] },
          _meta: { claude: { tool: "AskUserQuestion" } },
        },
      },
    };
    const question = questionFromPermission(record)!;
    expect(question.items[0]!.options.map((option) => option.id)).toEqual(["Same", "Same#2"]);
    expect(question.items[0]!.options.map((option) => option.label)).toEqual(["Same", "Same"]);
  });

  test("previews are detected per item", () => {
    expect(hasPreviews(expected("pending-with-preview").items[0]!)).toBe(true);
    expect(hasPreviews(expected("pending-single").items[0]!)).toBe(false);
  });
});

/// The answer round trip per harness: the reply a card sends must be the exact
/// `_acpmux/permission_respond` params the harness adapter reads.
describe("reply", () => {
  const answer = (selections: Answer["selections"]): Answer => ({ selections });

  test("Claude single select answers by question text", () => {
    const sent = reply(expected("pending-single"), answer({ q0: selection(["Passkeys"]) }));
    expect(sortedJSON(replyParams(sent))).toBe(
      `{"answers":{"Which auth method should the API use?":"Passkeys"},"optionId":"allow_once","permissionId":"perm_toolu_single","sessionId":"sess_claude_1"}`,
    );
  });

  test("Claude multi-select joins labels in option order, then Other", () => {
    const sent = reply(expected("pending-multi"), answer({ q0: selection(["Web", "macOS"], "  visionOS ") }));
    expect(sent.answers).toEqual({ "Which platforms should the first release support?": "macOS, Web, visionOS" });
  });

  test("Claude Other text answers alone", () => {
    const sent = reply(expected("pending-single"), answer({ q0: selection([], "Mutual TLS") }));
    expect(sent.answers).toEqual({ "Which auth method should the API use?": "Mutual TLS" });
  });

  test("Codex answers by id with arrays", () => {
    const sent = reply(
      expected("codex-user-input"),
      answer({ db_engine: selection(["SQLite"]), service_name: selection([], "ledger") }),
    );
    expect(sent.optionId).toBe("allow_once");
    expect(sent.answers).toEqual({ db_engine: { answers: ["SQLite"] }, service_name: { answers: ["ledger"] } });
  });

  test("ACP interactive answers with the chosen permission option", () => {
    const sent = reply(expected("acp-interactive"), answer({ q0: selection(["dry_run"]) }));
    expect(sent.optionId).toBe("dry_run");
    expect(sent.answers).toBeUndefined();
    expect(replyParams(sent)).toEqual({ sessionId: "sess_acp_1", permissionId: "perm_acp_1", optionId: "dry_run" });
  });

  test("the Chief answers like Claude", () => {
    const sent = reply(expected("chief-asks"), answer({ q0: selection(["wait"]) }));
    expect(sent.session).toBe("sess_mux");
    expect(sent.answers).toEqual({ "Two agents finished. Merge both branches into feat-cmux-next now?": "Wait" });
  });

  test("decline uses the reject option, never an allow", () => {
    for (const name of names) {
      const question = expected(name);
      const decline = declineReply(question)!;
      expect(decline, name).toBeDefined();
      expect(decline.optionId, name).toBe(question.source.rejectOption);
      expect(decline.optionId, name).not.toBe(question.source.answerOption);
      expect(decline.answers, name).toBeUndefined();
    }
  });

  test("a decline with no reject option cancels: params carry no optionId", () => {
    const question = expected("pending-single");
    const decline = declineReply({ ...question, source: { ...question.source, rejectOption: undefined } })!;
    expect(replyParams(decline)).toEqual({ sessionId: "sess_claude_1", permissionId: "perm_toolu_single" });
  });

  test("invalid answers are refused", () => {
    const single = expected("pending-single");
    expect(problemOf(() => reply(single, answer({})))).toEqual({ kind: "unanswered", item: "q0" });
    expect(problemOf(() => reply(single, answer({ q0: selection(["OAuth 2.0", "Passkeys"]) })))).toEqual({
      kind: "tooManyChoices",
      item: "q0",
    });
    expect(problemOf(() => reply(single, answer({ q0: selection(["Kerberos"]) })))).toEqual({
      kind: "unknownOption",
      item: "q0",
      option: "Kerberos",
    });
    const acp = expected("acp-interactive");
    expect(problemOf(() => reply(acp, answer({ q0: selection([], "maybe") })))).toEqual({
      kind: "otherNotAllowed",
      item: "q0",
    });
    const answered = expected("answered-collapsed");
    expect(problemOf(() => reply(answered, answer({ q0: selection(["Passkeys"]) })))).toEqual({ kind: "notPending" });
  });

  test("summary lines use headers", () => {
    const question = expected("pending-multi");
    expect(summaryLines(question, answer({ q0: selection(["iOS", "macOS"]) }))).toEqual(["Platforms: macOS, iOS"]);
  });

  test("selection trims Other and drops empty text", () => {
    expect(selection([], "  x ")).toEqual({ optionIDs: [], other: "x" });
    expect(selection(["a"], "   ")).toEqual({ optionIDs: ["a"] });
  });
});
