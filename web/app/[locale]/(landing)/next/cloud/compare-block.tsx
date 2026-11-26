import { printableCompareRows, type CloudCompareRow } from "../../../../../services/billing/cloudCompare";

type Translate = (key: string, values?: Record<string, string | number>) => string;

const COLUMNS = ["server", "planTab", "cmux"] as const;

/**
 * RFD 0135's comparison block. It renders only rows with a proof
 * (printableCompareRows), so a row we have not measured cannot print, and
 * nothing at all when no row is proven.
 */
export function CloudCompareBlock({ t, rows }: { t: Translate; rows?: readonly CloudCompareRow[] }) {
  const printable = printableCompareRows(rows);
  if (printable.length === 0) return null;
  return (
    <section className="mt-16" aria-labelledby="cloud-compare-title" data-testid="cloud-compare">
      <h2 id="cloud-compare-title" className="text-lg font-medium tracking-tight">
        {t("compare.title")}
      </h2>
      <p className="mt-1 text-sm text-muted">{t("compare.note")}</p>
      <div className="mt-4 overflow-x-auto">
        <table className="w-full min-w-[720px] border-collapse text-sm">
          <thead>
            <tr className="border-b border-border text-left text-muted">
              <th className="w-1/4 py-2 pr-4 font-normal" />
              {COLUMNS.map((column) => (
                <th key={column} className={`w-1/4 py-2 pr-4 font-normal ${column === "cmux" ? "text-foreground" : ""}`}>
                  {t(`compare.columns.${column}`)}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {printable.map((row) => (
              <tr key={row.id} className="border-b border-border align-top" data-testid={`cloud-compare-${row.id}`}>
                <th scope="row" className="py-3 pr-4 text-left font-medium">
                  {t(`compare.rows.${row.id}.label`, row.values)}
                </th>
                {COLUMNS.map((column) => (
                  <td key={column} className={`py-3 pr-4 ${column === "cmux" ? "font-medium" : "text-muted"}`}>
                    {t(`compare.rows.${row.id}.${column}`, row.values)}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}
