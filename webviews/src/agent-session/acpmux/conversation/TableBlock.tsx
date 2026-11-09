// A reply's Markdown table, with Open and Copy on its own top-right corner on hover or keyboard
// focus. Copy puts the Markdown, TSV and an HTML table on the clipboard, so it pastes into Sheets,
// Numbers or Notes as cells (tableFormats.ts); Open shows the table in the side panel.
//
// The table fits the column: its columns share the width by how much text each holds, and a
// cell's text wraps at word ends. Only a table whose unbreakable words cannot fit (a long path, a
// hash) scrolls sideways, in its own box, with the transcript's thin thumb and a fade at the edge
// while more lies past it (sideways.ts), never a word cut at the edge (Leo 2026-11-05, on a status
// table clipped mid-word with its actions far off to the right).
import { useContext, type ReactNode } from "react";
import { experimentArm } from "../../../experiments/experiment";
import { rowIconSize } from "../icons/iconSize";
import { useT } from "../i18n";
import { ArtifactContext } from "./artifactPreview";
import { SIDEWAYS_SCROLLER, useSidewaysRef } from "./blockPartsModel";
import { copyTextResult } from "./clipboard";
import { CopyButton } from "./CopyButton";
import { Expand } from "./icons";
import { tableActionsPlace } from "./tableActions.experiment";
import { copyTable, hasHeader, tableMarkdown, type Table } from "./tableFormats";

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
  const wrap = useSidewaysRef<HTMLDivElement>();
  const place = experimentArm(tableActionsPlace);
  // No empty header row: a table whose header is all blank draws its rows only. One with an empty
  // top-left corner labels its rows with its first column.
  const header = hasHeader(table);
  const labeled = header && !table.header[0]?.trim();
  const markdown = tableMarkdown(table);
  return (
    <div className={`cv-table-block${className}`} data-actions={place}>
      {/* Bare buttons on its corner, as a code card's (cornerActions.ts); only `above`, which sits
          over the line before the table, keeps the glass pill under them. */}
      <div className={`cv-table-tools${place === "above" ? " ui-glass" : ""}`}>
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
      <div className="cv-table-wrap" ref={wrap} {...SIDEWAYS_SCROLLER}>
        <table className={`cv-table${labeled ? " cv-table--labeled" : ""}`}>
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
