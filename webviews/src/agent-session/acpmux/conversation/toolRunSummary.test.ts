// l10n-allow-file: test fixtures.
// A settled run's sentence (Lucas, 2026-11-06: Codex parity): the two most telling kinds by
// name, commands and edits first, then "performed N other actions", joined as a sentence.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import type { Translate } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { toolRunSummary } from "./toolRunSummary";

// The catalog's English, with {n} filled in, so the test reads the words the pane shows.
type Unit = { stringUnit: { value: string } };
const catalog = JSON.parse(readFileSync(new URL("../Localizable.xcstrings", import.meta.url), "utf8")) as {
  strings: Record<string, { localizations: { en: Unit | { variations: { plural: Record<string, Unit> } } } }>;
};
const english = new Intl.PluralRules("en");
const t = ((key: string, values?: Record<string, string | number>) => {
  const en = catalog.strings[key]!.localizations.en;
  const unit = "variations" in en ? en.variations.plural[english.select(Number(values?.n ?? 0))]! : en;
  return unit.stringUnit.value.replace(/\{(\w+)\}/g, (_, name: string) => String(values?.[name]));
}) as Translate;

let next = 0;
const call = (kind: string, path?: string): AcpmuxActivity =>
  ({
    kind: "tool",
    text: "Step",
    tool: {
      id: `c${next++}`,
      title: "Step",
      kind,
      status: "completed",
      ...(path ? { locations: [{ path }] } : {}),
    },
  }) as AcpmuxActivity;

test("two kinds read as one sentence joined by and, in the order the run did them", () => {
  const run = [call("read", "a.ts"), call("read", "b.ts"), call("read", "c.ts"), call("execute"), call("execute")];
  expect(toolRunSummary(t, run)).toBe("Read 3 files and ran 2 commands");
});

test("past two kinds, commands and edits are named and the rest are other actions", () => {
  const run = [call("read", "a.ts"), call("search"), call("execute"), call("edit", "a.ts"), call("execute")];
  expect(toolRunSummary(t, run)).toBe("Ran 2 commands, edited a file, and performed 2 other actions");
});

test("one left-out call is one other action", () => {
  const run = [call("execute"), call("edit", "a.ts"), call("fetch")];
  expect(toolRunSummary(t, run)).toBe("Ran a command, edited a file, and performed 1 other action");
});

test("other tools are named last, after reads and searches", () => {
  const run = [call("other"), call("read", "a.ts"), call("search")];
  expect(toolRunSummary(t, run)).toBe("Read a file, ran a search, and performed 1 other action");
});

test("one kind is its own phrase", () => {
  expect(toolRunSummary(t, [call("execute"), call("execute")])).toBe("Ran 2 commands");
});
