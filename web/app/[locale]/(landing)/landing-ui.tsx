import { useTranslations } from "next-intl";
import { DownloadButton } from "@/app/[locale]/components/download-button";
import { GitHubButton } from "@/app/[locale]/components/github-button";
import { TrackedLink } from "./tracked-link";

/** Comparison/spec table. First cell of each row is rendered bold. */
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
export function LandingCTA({
  related,
}: {
  related?: { href: string; label: string }[];
}) {
  const t = useTranslations("landing.cta");
  return (
    <div className="not-prose mt-10 border-t border-border pt-8">
      <p className="text-base font-medium mb-4">{t("freeOpenSource")}</p>
      <div className="flex flex-wrap items-center gap-3">
        <DownloadButton location="landing" />
        <GitHubButton location="landing" />
      </div>
      {related && related.length > 0 ? (
        <div className="mt-8 text-sm">
          <div className="opacity-60 mb-2">{t("seeAlso")}</div>
          <ul className="flex flex-col gap-1">
            {related.map((r) => (
              <li key={r.href}>
                <TrackedLink href={r.href} event="guide_link_clicked">
                  {r.label}
                </TrackedLink>
              </li>
            ))}
          </ul>
        </div>
      ) : null}
    </div>
  );
}
