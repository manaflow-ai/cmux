import { Link } from "../../../i18n/navigation";
import { DownloadButton } from "../components/download-button";

/**
 * Comparison table. `headers` is the column row (first cell is usually the
 * dimension label, the rest are the products being compared). `rows` is a list
 * of cell arrays of the same length.
 */
export function CompareTable({
  headers,
  rows,
}: {
  headers: string[];
  rows: string[][];
}) {
  return (
    <table>
      <thead>
        <tr>
          {headers.map((h) => (
            <th key={h}>{h}</th>
          ))}
        </tr>
      </thead>
      <tbody>
        {rows.map((row) => (
          <tr key={row[0]}>
            {row.map((cell, i) => (
              <td key={i}>{i === 0 ? <strong>{cell}</strong> : cell}</td>
            ))}
          </tr>
        ))}
      </tbody>
    </table>
  );
}

/** Download CTA plus a row of related discovery links. */
export function CompareCTA({
  related,
}: {
  related?: { href: string; label: string }[];
}) {
  return (
    <div className="not-prose mt-10 border-t border-border pt-8">
      <p className="text-base font-medium mb-4">
        cmux is free and open source for macOS.
      </p>
      <div className="flex flex-wrap items-center gap-3">
        <DownloadButton location="compare" />
        <a
          href="https://github.com/manaflow-ai/cmux"
          className="text-sm opacity-70 hover:opacity-100"
        >
          View on GitHub
        </a>
      </div>
      {related && related.length > 0 ? (
        <div className="mt-8 text-sm">
          <div className="opacity-60 mb-2">See also</div>
          <ul className="flex flex-col gap-1">
            {related.map((r) => (
              <li key={r.href}>
                <Link href={r.href}>{r.label}</Link>
              </li>
            ))}
          </ul>
        </div>
      ) : null}
    </div>
  );
}
