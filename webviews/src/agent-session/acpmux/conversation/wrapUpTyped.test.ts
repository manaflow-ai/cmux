// l10n-allow-file: test fixture prompts, not shipped UI.
import { expect, test } from "bun:test";
import { isWrapUp, wrapUpAsk } from "./wrapUp";
import { mcpCall } from "./mcpCalls";

const ask = (args: unknown) =>
  wrapUpAsk({ title: "wrap_up", status: "completed", inputSummary: JSON.stringify(args) } as never);

test("typed actions keep their run, strings stay plain", () => {
  const got = ask({
    recap: "Built it.",
    ask: "Try it?",
    actions: [{ label: "Try it on", run: { customize: "try", target: "pr:7", minutes: 20 } }, "Not now"],
  });
  expect(got?.options).toEqual([
    { label: "Try it on", run: { customize: "try", target: "pr:7", minutes: 20 } },
    { label: "Not now" },
  ]);
});

test("a run the daemon would refuse is dropped, the label stays an answer", () => {
  const got = ask({ recap: "r", ask: "q", actions: [{ label: "Go", run: { customize: "try", target: "--rm" } }] });
  expect(got?.options).toEqual([{ label: "Go" }]);
});

test("an unlabelled typed action is named for its verb, an empty one is dropped", () => {
  const got = ask({
    recap: "r",
    ask: "q",
    actions: [{ run: { customize: "keep" } }, { run: { customize: "revert" } }, { run: { customize: "x" } }],
  });
  expect(got?.options.map((o) => o.label)).toEqual(["Keep", "Revert"]);
});

test("duplicates collapse", () => {
  const got = ask({ recap: "r", ask: "q", actions: ["A", { label: "A", run: { customize: "keep" } }] });
  expect(got?.options.map((o) => o.label)).toEqual(["A"]);
});

test("the wrap-up call counts under the agent server's name and the one before the rename", () => {
  const call = (title: string, inputSummary = "{}") => ({ title, status: "completed", inputSummary }) as never;
  for (const title of ["mcp__cmux-agent__wrap_up", "mcp__acpmux__wrap_up", "mcp__cmux__acpmux_wrap_up"]) {
    expect(isWrapUp(call(title))).toBe(true);
  }
  expect(isWrapUp(call("cmux-agent.wrap_up"))).toBe(true);
  const codex = (server: string) =>
    call("wrap_up", JSON.stringify({ server, tool: "wrap_up", arguments: { recap: "Done." } }));
  expect(isWrapUp(codex("cmux-agent"))).toBe(true);
  expect(isWrapUp(codex("acpmux"))).toBe(true);
  expect(isWrapUp(codex("github"))).toBe(false);
  expect(isWrapUp(call("mcp__github__wrap_up"))).toBe(false);
  expect(mcpCall(call("mcp__cmux-agent__send"))?.server).toBe("acpmux");
});
