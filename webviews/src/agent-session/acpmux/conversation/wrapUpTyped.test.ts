// l10n-allow-file: test fixture prompts, not shipped UI.
import { expect, test } from "bun:test";
import { wrapUpAsk } from "./wrapUp";

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
