import { describe, expect, test } from "bun:test";
import { BOM, LineEndings, analyzeText, lineEndingLabel, type LineChange } from "./textCodec";

/** Monaco's view of a body: its lines (any of CRLF, LF, CR breaks a line). */
const linesOf = (body: string) => body.split(/\r\n|\r|\n/);

/** Applies one edit to plain lines the way Monaco does, and reports the change event. */
function edit(lines: string[], line: number, column: number, endLine: number, endColumn: number, text: string) {
  const before = lines[line - 1].slice(0, column - 1);
  const after = lines[endLine - 1].slice(endColumn - 1);
  const inserted = `${before}${text}${after}`.split(/\r\n|\r|\n/);
  lines.splice(line - 1, endLine - line + 1, ...inserted);
  const change: LineChange = { startLineNumber: line, endLineNumber: endLine, text };
  return change;
}

describe("analyzeText", () => {
  test("a uniform LF file needs no per-line endings", () => {
    const shape = analyzeText("a\nb\n");
    expect(shape).toEqual({ bom: false, eol: "\n", endings: null, body: "a\nb\n" });
  });

  test("a uniform CRLF file keeps CRLF as Monaco's EOL", () => {
    const shape = analyzeText("a\r\nb");
    expect(shape.eol).toBe("\r\n");
    expect(shape.endings).toBeNull();
  });

  test("a BOM is split off, mixed and lone CR endings are kept per line", () => {
    const shape = analyzeText(`${BOM}a\r\nb\nc\rd`);
    expect(shape.bom).toBe(true);
    expect(shape.body).toBe("a\r\nb\nc\rd");
    expect(shape.endings).toEqual(["\r\n", "\n", "\r"]);
    expect(lineEndingLabel(shape)).toBe("mixed");
  });

  test("a file of lone CRs is not uniform for Monaco (it has no CR EOL)", () => {
    const shape = analyzeText("a\rb\r");
    expect(shape.eol).toBe("\r");
    expect(shape.endings).toEqual(["\r", "\r"]);
    expect(lineEndingLabel(shape)).toBe("CR");
  });
});

describe("LineEndings", () => {
  const roundTrip = (text: string) => {
    const shape = analyzeText(text);
    return new LineEndings(shape).encode(linesOf(shape.body));
  };

  test("an unedited file encodes to its exact text", () => {
    for (const text of [
      "",
      "\n",
      "no final newline",
      "a\nb\n",
      "a\r\nb\r\n",
      `${BOM}x\r\ny`,
      "a\r\nb\nc\rd\r\n",
      "\r\n\r\n\n",
      `${BOM}`,
    ]) {
      expect(roundTrip(text)).toBe(text);
    }
  });

  test("an edit inside a line keeps every line's ending", () => {
    const shape = analyzeText("one\r\ntwo\nthree\rfour");
    const endings = new LineEndings(shape);
    const lines = linesOf(shape.body);
    endings.apply([edit(lines, 2, 4, 2, 4, "!")]);
    expect(endings.encode(lines)).toBe("one\r\ntwo!\nthree\rfour");
  });

  test("a new line break gets the file's usual ending; joined lines lose theirs", () => {
    const shape = analyzeText("a\r\nb\r\nc\nd\r\n");
    const endings = new LineEndings(shape);
    expect(endings.eol).toBe("\r\n");
    const lines = linesOf(shape.body);
    // Split line 3 ("c") in two.
    endings.apply([edit(lines, 3, 2, 3, 2, "\nX")]);
    expect(endings.encode(lines)).toBe("a\r\nb\r\nc\r\nX\nd\r\n");
    // Join lines 1 and 2: the ending between them goes.
    endings.apply([edit(lines, 1, 2, 2, 1, "")]);
    expect(endings.encode(lines)).toBe("ab\r\nc\r\nX\nd\r\n");
  });

  test("several changes of one event apply from the end of the document", () => {
    const shape = analyzeText("1\n2\r\n3\n4\r\n");
    const endings = new LineEndings(shape);
    const lines = linesOf(shape.body);
    // Monaco orders a multi-cursor event's changes from the end of the document.
    const second = edit(lines, 3, 2, 3, 2, "b");
    const first = edit(lines, 1, 2, 1, 2, "a");
    endings.apply([second, first]);
    expect(endings.encode(lines)).toBe("1a\n2\r\n3b\n4\r\n");
  });

  test("a BOM and a missing final newline survive edits", () => {
    const shape = analyzeText(`${BOM}x\r\ny`);
    const endings = new LineEndings(shape);
    const lines = linesOf(shape.body);
    endings.apply([edit(lines, 2, 2, 2, 2, "z")]);
    expect(endings.encode(lines)).toBe(`${BOM}x\r\nyz`);
  });
});
