// A reply's table (TableBlock.tsx): Copy puts its Markdown, an HTML table and TSV on the clipboard
// (tableFormats.ts), so it pastes into Sheets or Notes as cells; its columns fit their text.
import { afterEach, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { ArtifactContext } from "../src/agent-session/acpmux/conversation/artifactPreview";
import { parseMarkdown, Markdown } from "../src/agent-session/acpmux/conversation/Markdown";
import {
  copyTable,
  tableClipboard,
  tableHtml,
  tableMarkdown,
  tableTsv,
  type Table,
} from "../src/agent-session/acpmux/conversation/tableFormats";

// The reply Leo saw (2026-10-20), with inline Markdown and an alignment added.
const source = `| | Count |
| --- | ---: |
| **Dropping** as useless | 91 |
| Keeping, getting the \`styled\` look | 22 |
| Keeping as they are & < 5 | the rest |`;

const table = parseMarkdown(source)[0] as Table & { type: "table" };

test("the Markdown keeps the cells' syntax and the columns' alignment", () => {
  expect(tableMarkdown(table)).toBe(
    [
      "|  | Count |",
      "| --- | ---: |",
      "| **Dropping** as useless | 91 |",
      "| Keeping, getting the `styled` look | 22 |",
      "| Keeping as they are & < 5 | the rest |",
    ].join("\n"),
  );
});

test("TSV has the cells' words, one row per line", () => {
  expect(tableTsv(table)).toBe(
    [
      "\tCount",
      "Dropping as useless\t91",
      "Keeping, getting the styled look\t22",
      "Keeping as they are & < 5\tthe rest",
    ].join("\n"),
  );
});

test("the HTML table escapes its cells and keeps alignment", () => {
  expect(tableHtml(table)).toBe(
    '<table><thead><tr><th></th><th style="text-align:right">Count</th></tr></thead><tbody>' +
      '<tr><td>Dropping as useless</td><td style="text-align:right">91</td></tr>' +
      '<tr><td>Keeping, getting the styled look</td><td style="text-align:right">22</td></tr>' +
      '<tr><td>Keeping as they are &amp; &lt; 5</td><td style="text-align:right">the rest</td></tr>' +
      "</tbody></table>",
  );
});

test("a short row is padded to the table's columns", () => {
  const ragged: Table = { align: [null, null], header: ["a", "b"], rows: [["1"]] };
  expect(tableTsv(ragged)).toBe("a\tb\n1\t");
  expect(tableMarkdown(ragged)).toBe("| a | b |\n| --- | --- |\n| 1 |  |");
});

test("a blank header pastes as no header row; the Markdown keeps it", () => {
  const blank: Table = { align: [null, null], header: ["", " "], rows: [["a", "1"]] };
  expect(tableTsv(blank)).toBe("a\t1");
  expect(tableHtml(blank)).toBe("<table><tbody><tr><td>a</td><td>1</td></tr></tbody></table>");
  expect(tableMarkdown(blank)).toBe("|  |   |\n| --- | --- |\n| a | 1 |");
});

test("a cell that reads as block Markdown pastes as its text", () => {
  const cells: Table = { align: [null, null, null], header: ["a", "b", "c"], rows: [["---", "# x", "> y"]] };
  expect(tableTsv(cells)).toBe("a\tb\tc\n---\t# x\t> y");
});

const scope = globalThis as Record<string, unknown>;
const saved = { navigator: scope.navigator, ClipboardItem: scope.ClipboardItem };
afterEach(() => {
  Object.defineProperty(globalThis, "navigator", { value: saved.navigator, configurable: true });
  scope.ClipboardItem = saved.ClipboardItem;
});

class FakeClipboardItem {
  static supports = (type: string) => ["text/plain", "text/html", "text/tab-separated-values"].includes(type);
  constructor(readonly items: Record<string, Blob>) {}
}

test("Copy writes Markdown as text, the HTML table and TSV in one clipboard entry", async () => {
  const written: FakeClipboardItem[][] = [];
  scope.ClipboardItem = FakeClipboardItem;
  Object.defineProperty(globalThis, "navigator", {
    value: { clipboard: { write: async (items: FakeClipboardItem[]) => void written.push(items) } },
    configurable: true,
  });
  const fallback: string[] = [];
  expect(await copyTable(table, async (text) => (fallback.push(text), true))).toBe(true);
  expect(fallback).toEqual([]);
  expect(written).toHaveLength(1);
  const entry = written[0]![0]!.items;
  expect(Object.keys(entry).sort()).toEqual(["text/html", "text/plain", "text/tab-separated-values"]);
  expect(await entry["text/plain"]!.text()).toBe(tableMarkdown(table));
  expect(await entry["text/html"]!.text()).toBe(tableHtml(table));
  expect(await entry["text/tab-separated-values"]!.text()).toBe(tableTsv(table));
});

test("a clipboard without that type gets Markdown and HTML only", () => {
  scope.ClipboardItem = class {
    static supports = (type: string) => type !== "text/tab-separated-values";
  };
  expect(Object.keys(tableClipboard(table)).sort()).toEqual(["text/html", "text/plain"]);
});

test("where the page cannot write a clipboard entry, Copy copies the Markdown", async () => {
  scope.ClipboardItem = undefined;
  Object.defineProperty(globalThis, "navigator", { value: {}, configurable: true });
  const fallback: string[] = [];
  expect(await copyTable(table, async (text) => (fallback.push(text), true))).toBe(true);
  expect(fallback).toEqual([tableMarkdown(table)]);
});

test("the table draws with Copy, columns that fit their text and labeled rows", () => {
  const html = renderToStaticMarkup(
    <ArtifactContext.Provider value={() => {}}>
      <Markdown>{source}</Markdown>
    </ArtifactContext.Provider>,
  );
  expect(html).toContain('class="cv-table-tools"');
  expect(html).toContain('aria-label="Copy table"');
  expect(html).toContain('class="cv-table cv-table--labeled"');
  expect(html.match(/width="14" height="14"/g)).toHaveLength(2);
  // No fixed 128px column: a short column is as wide as its text.
  expect(html).not.toContain("width:128");
});

test("a table whose header is all blank draws no header row", () => {
  const html = renderToStaticMarkup(<Markdown>{"| | |\n| --- | --- |\n| a | 1 |"}</Markdown>);
  expect(html).not.toContain("<thead");
  expect(html).toContain("<td");
});
