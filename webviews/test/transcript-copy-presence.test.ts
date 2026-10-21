import { expect, test } from "bun:test";
import { hasTranscriptCopyText, transcriptCopyText } from "../src/agent-session/acpmux/conversation/transcriptCopy";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

// The floating Copy asks every visible row on every scroll frame whether it has text to copy.
// hasTranscriptCopyText answers that without building the copy string, and must agree with it.
const row = (fields: Partial<AcpmuxRow>): AcpmuxRow => ({ id: "r", version: 1, at: 0, kind: "tool", ...fields });
const shell = (command: string, output: string, error?: string) => ({ command, output, error }) as AcpmuxRow["shell"];
const tool = (output: string | undefined, text = "") => ({
  kind: "tool",
  text,
  tool: { id: "t", title: "Run", status: "completed", output },
});

const cases: Array<[string, AcpmuxRow]> = [
  ["empty row", row({})],
  ["blank text", row({ text: " \n\t ﻿" })],
  ["text", row({ text: "hello" })],
  ["blank shell", row({ shell: shell(" ", "\n", "\t") })],
  ["shell command", row({ shell: shell("ls", "") })],
  ["shell output", row({ shell: shell("", " out ") })],
  ["shell error", row({ shell: shell("", "", "boom") })],
  ["blank items", row({ items: [tool(" "), tool(undefined, "\n")] })],
  ["item text", row({ items: [tool(undefined, "thinking")] })],
  ["item output after blanks", row({ items: [tool(""), tool(" "), tool("result")] })],
];

for (const [name, value] of cases) {
  test(`hasTranscriptCopyText agrees with transcriptCopyText: ${name}`, () => {
    expect(hasTranscriptCopyText(value)).toBe(transcriptCopyText(value).length > 0);
  });
}

test("hasTranscriptCopyText stops at the first non-blank part", () => {
  let reads = 0;
  const items = Array.from({ length: 1000 }, (_, index) => ({
    kind: "tool",
    get text() {
      reads++;
      return index === 0 ? "first" : "later";
    },
  })) as AcpmuxRow["items"];
  expect(hasTranscriptCopyText(row({ items }))).toBe(true);
  expect(reads).toBe(1);
});
