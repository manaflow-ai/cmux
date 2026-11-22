import { expect, test } from "bun:test";
import fixture from "../../../test/fixtures/new-tab-intents.json";
import { classifyNewTabInput, type NewTabIntent } from "./newTabIntent";

type Row = { input: string; intent: NewTabIntent };

// One table for both classifiers: the Swift NewTabIntentTests reads the same file. One input
// (R86): plain text is a prompt; a web search is only an explicit row, never a mode.
for (const row of fixture.rows as Row[]) {
  test(`${JSON.stringify(row.input)} is ${row.intent.kind}`, () => {
    expect(classifyNewTabInput(row.input, { home: fixture.home })).toEqual(row.intent);
  });
}

test("without a home folder, ~ is text rather than a guessed path", () => {
  expect(classifyNewTabInput("~/code", {})).toEqual({ kind: "prompt", text: "~/code" });
});
