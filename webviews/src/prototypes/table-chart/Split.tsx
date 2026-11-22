// l10n-allow-file: isolated gallery prototype, not shipped UI.
import { Chart, Controls, ExportButtons, Shell, Table, useTableData, type Props } from "./shared";
export function Split({ fixture }: Props) {
  const api = useTableData(fixture);
  return (
    <Shell
      title="Compare source and shape"
      description="Read the rows and chart together before sharing a conclusion."
      controls={<Controls api={api} compact />}
    >
      <section className="tc-card tc-split">
        <div>
          <Table rows={api.rows} />
        </div>
        <div className="tc-chart-pane">
          <Chart rows={api.rows} series={api.series} kind={api.kind} title="Side-by-side preview" />
        </div>
      </section>
      <ExportButtons rows={api.rows} />
    </Shell>
  );
}
