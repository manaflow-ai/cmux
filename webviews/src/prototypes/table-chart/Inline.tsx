// l10n-allow-file: isolated gallery prototype, not shipped UI.
import { useState } from "react";
import { Chart, Controls, ExportButtons, Shell, Table, useTableData, type Props } from "./shared";
export function Inline({ fixture }: Props) {
  const api = useTableData(fixture);
  const [view, setView] = useState<"chart" | "table">("chart");
  return (
    <Shell
      title="Visualize this table"
      description="Switch between the source and its chart without leaving the reply."
      controls={<Controls api={api} />}
    >
      <section className="tc-card tc-inline">
        <fieldset className="tc-view-toggle" aria-label="Preview view">
          <button type="button" aria-pressed={view === "chart"} onClick={() => setView("chart")}>
            Show chart
          </button>
          <button type="button" aria-pressed={view === "table"} onClick={() => setView("table")}>
            Show source
          </button>
        </fieldset>
        {view === "chart" ? (
          <div className="tc-chart-pane">
            <Chart rows={api.rows} series={api.series} kind={api.kind} />
          </div>
        ) : (
          <Table rows={api.rows} />
        )}
      </section>
      <ExportButtons rows={api.rows} chartVisible={view === "chart"} />
    </Shell>
  );
}
