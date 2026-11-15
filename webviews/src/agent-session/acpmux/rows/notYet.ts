// The fields the view reads that the store and adapter do not give as v1 does yet (decision 233):
// each with its home (decision 229, FIELDS.md) and the row that builds it. The parity test fails
// when a field off this list differs from v1 over the corpus, and when a field on it no longer
// differs anywhere in the corpus, so the list only shrinks. Empty is a done-when of row 13.
// A key is `<view row kind>.<field>`; a tool call's fields are `tool.<field>`.

export type Home = "a" | "b" | "c" | "d" | "e" | "f" | "g";
export type Builder = "2c" | "2d" | "A0" | "row 11";

export type NotYet = { field: string; home: Home; builder: Builder; note: string };

export const NOT_YET: readonly NotYet[] = [
  {
    field: "assistant.turnStartedAtMs",
    home: "b",
    builder: "2c",
    note: "the group row's start, in ms (decision 231)",
  },
  {
    field: "turnSummary.turnStartedAtMs",
    home: "b",
    builder: "2c",
    note: "the group row's start, in ms (decision 231)",
  },
  { field: "tool.startedAt", home: "a", builder: "2c", note: "in ms on tool rows (decision 231)" },
  { field: "tool.endedAt", home: "a", builder: "2c", note: "in ms on tool rows (decision 231)" },
  {
    field: "tool.approved",
    home: "a",
    builder: "2c",
    note: "an approval reads on its call; the ask row draws no receipt for it",
  },
  {
    field: "tool.provenance",
    home: "a",
    builder: "2c",
    note: "Claude's tool name (`_meta.claude.tool`), with Claude's title and kind",
  },
  // The row head's `at` is in seconds; v1 keeps the record's ms.
  { field: "user.at", home: "a", builder: "2c", note: "the row head's `at` in ms" },
  { field: "assistant.at", home: "a", builder: "2c", note: "the row head's `at` in ms" },
  { field: "tool.at", home: "a", builder: "2c", note: "the row head's `at` in ms" },
  { field: "turnSummary.at", home: "a", builder: "2c", note: "the row head's `at` in ms" },
];
