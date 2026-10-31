// l10n-allow-file: isolated gallery prototype, not shipped UI.
import { Chart, Controls, ExportButtons, Shell, Table, useTableData, type Props } from "./shared";
export function Focus({ fixture }: Props) {
  const api = useTableData(fixture);
  return (
    <Shell
      title="Chart workspace"
      description="Give a visualization room, with the source one disclosure away."
      controls={<Controls api={api} />}
    >
      <section className="tc-card tc-focus">
        <div className="tc-chart-pane">
          <Chart rows={api.rows} series={api.series} kind={api.kind} title="Focused preview" />
        </div>
        <details>
          <summary>Show source table ({api.rows.length.toLocaleString()} rows)</summary>
          <Table rows={api.rows} />
        </details>
      </section>
      <ExportButtons rows={api.rows} />
    </Shell>
  );
}
