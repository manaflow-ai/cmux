/**
 * Expression semantics, checked against the GitHub documentation for
 * literals, operators, coercion and functions:
 * https://docs.github.com/en/actions/reference/workflows-and-actions/expressions
 */

import { describe, expect, it } from "vitest";
import {
  type EvalContext,
  evaluate,
  evaluateCondition,
  evaluateTemplate,
  ExpressionError,
  parseCondition,
  parseExpression,
  usesStatusFunction,
  type Value,
} from "../src/expr/index.ts";

const ctx = (contexts: Record<string, Value> = {}, status?: EvalContext["status"]): EvalContext =>
  status === undefined ? { contexts } : { contexts, status };

const github = {
  event_name: "push",
  repository: "manaflow-ai/cmux",
  repository_owner: "manaflow-ai",
  run_attempt: "1",
  event: { ref: "refs/heads/main" },
};

const ev = (source: string, contexts: Record<string, Value> = { github }): Value => evaluate(source, ctx(contexts));

describe("literals", () => {
  it.each([
    ["null", null],
    ["true", true],
    ["FALSE", false],
    ["42", 42],
    ["-9.2", -9.2],
    ["0xff", 255],
    ["-2.99e-2", -0.0299],
    ["'Mona the ''Octocat'''", "Mona the 'Octocat'"],
  ] as const)("%s", (source, expected) => {
    expect(ev(source)).toEqual(expected);
  });
});

describe("operators and coercion", () => {
  it.each([
    ["1 == '1'", true],
    ["'abc' == 'ABC'", true],
    ["null == 0", true],
    ["'' == 0", true],
    ["true == 1", true],
    ["'true' == true", false],
    ["fromJSON('{}') == fromJSON('{}')", false],
    ["1 != 2", true],
    ["1 < 2", true],
    ["'a' < 'B'", true],
    ["'10' > 9", true],
    ["'x' > 1", false],
    ["!''", true],
    ["!'false'", false],
    ["!0", true],
    ["'' || 'default'", "default"],
    ["'a' && 'b'", "b"],
    ["0 && 'x'", 0],
    ["(1 == 1) && !(2 == 3)", true],
    ["github.run_attempt > 1", false],
  ] as const)("%s", (source, expected) => {
    expect(ev(source)).toEqual(expected);
  });

  it("returns operand values from || chains like runs-on selectors", () => {
    const selector =
      "github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository && 'blacksmith-4vcpu-ubuntu-2404' || vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404'";
    expect(ev(selector, { github, vars: {} })).toBe("blacksmith-4vcpu-ubuntu-2404");
    expect(ev(selector, { github, vars: { LINUX_RUNNER: "blacksmith-8vcpu-ubuntu-2404" } })).toBe("blacksmith-8vcpu-ubuntu-2404");
    expect(ev(selector, { github: { ...github, repository_owner: "someone" }, vars: {} })).toBe("ubuntu-24.04");
  });
});

describe("property access", () => {
  it("reads missing properties as null", () => {
    expect(ev("github.event.pull_request.head.repo.full_name")).toBeNull();
  });

  it("ignores case in context and property names", () => {
    expect(ev("GITHUB.EVENT_NAME")).toBe("push");
  });

  it("indexes objects by string and arrays by number", () => {
    const steps = { "rustfmt-check": { outcome: "failure" } };
    expect(ev("steps['rustfmt-check'].outcome", { steps })).toBe("failure");
    expect(ev("steps.rustfmt-check.outcome", { steps })).toBe("failure");
    expect(ev("fromJSON('[10,20,30]')[1]")).toBe(20);
    expect(ev("fromJSON('[10,20,30]')[7]")).toBeNull();
  });

  it("maps property access over a * filter", () => {
    expect(ev("fromJSON('[{\"name\":\"a\"},{\"name\":\"b\"},{\"other\":1}]').*.name")).toEqual(["a", "b"]);
    expect(ev("contains(fromJSON('[{\"name\":\"a\"},{\"name\":\"b\"}]').*.name, 'B')")).toBe(true);
  });

  it("indexes the result of a call", () => {
    expect(ev("fromJSON('{\"shard-1\":\"x\"}')[format('shard-{0}', 1)]")).toBe("x");
    expect(ev("fromJSON(vars.SAVED || '{\"probe\":\"\"}').probe", { vars: {} })).toBe("");
  });
});

describe("functions", () => {
  it.each([
    ["contains('Hello world', 'LLO')", true],
    ["contains(fromJSON('[\"push\",\"pull_request\"]'), github.event_name)", true],
    ["contains(fromJSON('[\"push\"]'), 'pull')", false],
    ["startsWith('Hello world', 'he')", true],
    ["endsWith('Hello world', 'WORLD')", true],
    ["format('Hello {0} {1} {2}', 'Mona', 'the', 'Octocat')", "Hello Mona the Octocat"],
    ["format('{{Hello {0}}}', 'x')", "{Hello x}"],
    ["format('{0}/{1}', 1.5, 3)", "1.5/3"],
    ["join(fromJSON('[\"a\",\"b\"]'), ', ')", "a, b"],
    ["join(fromJSON('[\"a\",\"b\"]'))", "a,b"],
    ["join('abc')", "abc"],
    ["toJSON(fromJSON('{\"a\":1}'))", '{\n  "a": 1\n}'],
    ["fromJSON('true')", true],
    ["always()", true],
  ] as const)("%s", (source, expected) => {
    expect(ev(source)).toEqual(expected);
  });

  it("rejects bad fromJSON input and bad format strings", () => {
    expect(() => ev("fromJSON('')")).toThrow(ExpressionError);
    expect(() => ev("fromJSON(null)")).toThrow(ExpressionError);
    expect(() => ev("format('{1}', 'a')")).toThrow(ExpressionError);
  });

  it("needs a host for hashFiles", () => {
    expect(() => ev("hashFiles('**/Cargo.lock')")).toThrow(ExpressionError);
    const context: EvalContext = { contexts: {}, hashFiles: (patterns) => `h:${patterns.join("|")}` };
    expect(evaluate("hashFiles('a', 'b')", context)).toBe("h:a|b");
  });

  it("rejects unknown functions, unknown contexts and wrong arity", () => {
    expect(() => parseExpression("frobnicate(1)")).toThrow(/unrecognized function/);
    expect(() => parseExpression("foo.bar")).toThrow(/unrecognized named-value/);
    expect(() => parseExpression("contains('a')")).toThrow(/arguments/);
    expect(() => parseExpression("1 +")).toThrow(ExpressionError);
    expect(() => parseExpression("'open")).toThrow(/unterminated/);
  });
});

describe("templates", () => {
  it("keeps the type of a lone expression", () => {
    expect(evaluateTemplate("${{ 1 == 1 }}", ctx())).toBe(true);
    expect(evaluateTemplate("  ${{ fromJSON('[1]') }}\n", ctx())).toEqual([1]);
  });

  it("concatenates mixed text as strings", () => {
    expect(evaluateTemplate("x-${{ 1 }}-${{ true }}-${{ null }}", ctx())).toBe("x-1-true-");
    expect(evaluateTemplate("lint (${{ matrix.os }})", ctx({ matrix: { os: "linux" } }))).toBe("lint (linux)");
  });

  it("allows }} inside string literals", () => {
    expect(evaluateTemplate("${{ '}}' }}", ctx())).toBe("}}");
  });

  it("returns text without expressions unchanged", () => {
    expect(evaluateTemplate("plain", ctx())).toBe("plain");
  });

  it("rejects an unclosed expression", () => {
    expect(() => evaluateTemplate("${{ 1 ", ctx())).toThrow(/unclosed/);
  });
});

describe("conditions", () => {
  const failed = { success: () => false, failure: () => true, cancelled: () => false };

  it("adds success() when no status function is used", () => {
    expect(usesStatusFunction(parseCondition("github.event_name == 'push'"))).toBe(true);
    expect(evaluateCondition("github.event_name == 'push'", ctx({ github }))).toBe(true);
    expect(evaluateCondition("github.event_name == 'push'", ctx({ github }, failed))).toBe(false);
  });

  it("keeps explicit status functions", () => {
    expect(evaluateCondition("always() && github.event_name == 'push'", ctx({ github }, failed))).toBe(true);
    expect(evaluateCondition("${{ failure() }}", ctx({}, failed))).toBe(true);
    expect(evaluateCondition("${{\n  always() &&\n  inputs.package_npm\n}}", ctx({ inputs: { package_npm: false } }))).toBe(false);
  });

  it("treats an empty condition as success()", () => {
    expect(evaluateCondition("", ctx())).toBe(true);
    expect(evaluateCondition("", ctx({}, failed))).toBe(false);
  });

  it("accepts YAML booleans", () => {
    expect(evaluateCondition("false", ctx())).toBe(false);
    expect(evaluateCondition("true", ctx())).toBe(true);
  });
});
