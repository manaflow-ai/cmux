import { expect, test } from "bun:test";
import fixture from "../../../test/fixtures/new-tab-intents.json";
import { classifyNewTabInput, type NewTabIntent, type NewTabMode } from "./newTabIntent";

type Row = { input: string; mode?: NewTabMode; intent: NewTabIntent };

// One table for both classifiers: the Swift NewTabIntentTests reads the same file.
for (const row of fixture.rows as Row[]) {
  const mode = row.mode ?? "ask";
  test(`${JSON.stringify(row.input)} in ${mode} mode is ${row.intent.kind}`, () => {
    expect(classifyNewTabInput(row.input, mode, { home: fixture.home })).toEqual(row.intent);
  });
}

test("without a home folder, ~ is text rather than a guessed path", () => {
  expect(classifyNewTabInput("~/code", "ask", {})).toEqual({ kind: "prompt", text: "~/code" });
});

test("the mode never changes a command or an address", () => {
  for (const input of ["!make", "github.com", "localhost:3000"]) {
    expect(classifyNewTabInput(input, "ask", {})).toEqual(classifyNewTabInput(input, "search", {}));
  }
});
