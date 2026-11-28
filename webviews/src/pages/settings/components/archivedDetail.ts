import type { ArchivedEntryWire } from "../ops";
import { t } from "../strings";

/** The line under the name: the group and the computer, or "Link" for a link, tab or app row. */
export function archivedDetail(row: ArchivedEntryWire): string {
  if (row.kind === "item") return t("settingsPage.archived.kindLink");
  return [row.group, row.machine].filter((part): part is string => !!part && part.trim() !== "").join(" · ");
}
