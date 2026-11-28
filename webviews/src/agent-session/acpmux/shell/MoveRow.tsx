// Where a started chat moved from the location row: one quiet line, like the date line.
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";

export function MoveRow({ row }: { row: AcpmuxRow }) {
  const t = useT();
  if (!row.text) return null;
  return <p className="cv-date-line acpmux-move-line">{t("shell.moved", { place: row.text })}</p>;
}
