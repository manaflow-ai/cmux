// A reply's Markdown table, with Open and Copy at its top-right corner on hover or keyboard focus
// (the message rows' icon buttons). Copy puts the Markdown, TSV and an HTML table on the clipboard,
// so it pastes into Sheets, Numbers or Notes as cells (tableFormats.ts); Open shows the table in
// the side panel.
import { useContext, type ReactNode } from "react";
import { rowIconSize } from "../icons/iconSize";
import { useT } from "../i18n";
import { ArtifactContext } from "./artifactPreview";
import { copyTextResult } from "./clipboard";
import { CopyButton } from "./CopyButton";
import { Expand } from "./icons";
import { copyTable, hasHeader, tableMarkdown, type Table } from "./tableFormats";

/// Columns with a cell over this many characters are 256px at least (a table cell's width is its
/// minimum), so their text wraps there instead of in a sliver; every other column fits its text.
const LONG_CELL = 40;
const TABLE_ACTION_ICON_SIZE = rowIconSize(12);

export function TableBlock({
  table,
  cell,
  className = "",
}: {
  table: Table;
  /** Draws a cell's inline Markdown (Markdown.tsx renderInline). */
  cell: (text: string) => ReactNode;
  className?: string;
}) {
  const t = useT();
  const open = useContext(ArtifactContext);
  const plain = (text: string) => text.replace(/[`*_~]|\[|\]\([^)]*\)/g, "");
  const wide = table.header.map((_, i) => table.rows.some((row) => plain(row[i] ?? "").length > LONG_CELL));
  // No empty header row: a table whose header is all blank draws its rows only. One with an empty
  // top-left corner labels its rows with its first column.
  const header = hasHeader(table);
  const labeled = header && !table.header[0]?.trim();
  const markdown = tableMarkdown(table);
  return (
    <div className={`cv-table-block${className}`}>
      <div className="cv-table-tools">
        {open && (
          <button
            type="button"
            className="cv-iconbtn cv-iconbtn--compact"
            aria-label={t("table.open")}
            title={t("table.open")}
            onClick={() => open({ kind: "markdown", lang: "markdown", code: markdown })}
          >
            <Expand size={TABLE_ACTION_ICON_SIZE} />
          </button>
        )}
        <CopyButton
          text={markdown}
          label={t("table.copy")}
          className="cv-iconbtn cv-iconbtn--compact"
          size={TABLE_ACTION_ICON_SIZE}
          copy={() => copyTable(table, copyTextResult)}
        />
      </div>
      <div className="cv-table-wrap">
        <table className={`cv-table${labeled ? " cv-table--labeled" : ""}`}>
          <colgroup>
            {wide.map((long, i) => (
              <col key={i} style={long ? { width: 256 } : undefined} />
            ))}
          </colgroup>
          {header && (
            <thead>
              <tr>
                {table.header.map((text, i) => (
                  <th key={i} style={{ textAlign: table.align[i] ?? "left" }}>
                    {cell(text)}
                  </th>
                ))}
              </tr>
            </thead>
          )}
          <tbody>
            {table.rows.map((row, ri) => (
              <tr key={ri}>
                {row.map((text, i) => (
                  <td key={i} style={{ textAlign: table.align[i] ?? "left" }}>
                    {cell(text)}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
