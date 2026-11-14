// A card's More Options row and the rows it opens in place (rowLevels.ts).
import { useId, useState } from "react";
import type { SchemaRow } from "../schema";
import { SettingRow } from "./SettingRow";
import { Icon } from "../icons";
import { t } from "../strings";

/**
 * The card's last row toggles the rows behind it, which open below it in the same card (standup
 * 2026-11-11: no modal, no card inside a card). The toggle never moves: the rows open under it,
 * and its label and count stay the same; only the chevron turns. The rows mount on first open.
 */
export function MoreOptions({ rows, focus }: { rows: SchemaRow[]; focus?: string | null }) {
  const id = useId();
  // A link to a row behind the toggle opens it, on the first draw and on any later link.
  const linked = rows.some((row) => row.key === focus);
  const [open, setOpen] = useState(linked);
  const [mounted, setMounted] = useState(open);
  const [seenFocus, setSeenFocus] = useState(focus);
  if (seenFocus !== focus) {
    setSeenFocus(focus);
    if (linked && !open) {
      setOpen(true);
      setMounted(true);
    }
  }
  return (
    <>
      <button
        type="button"
        className="more-options"
        aria-expanded={open}
        aria-controls={id}
        data-open={open ? "" : undefined}
        onClick={() => {
          setMounted(true);
          setOpen(!open);
        }}
      >
        <span className="more-options-label">{t("settingsPage.moreOptions")}</span>
        <span className="more-options-count">{rows.length}</span>
        <Icon name="chevron" className="more-options-chevron" />
      </button>
      <div className="collapse more-options-rows" id={id} data-open={open ? "" : undefined} inert={!open}>
        <div className="collapse-body">
          {mounted && rows.map((row) => <SettingRow key={row.key} row={row} focused={row.key === focus} />)}
        </div>
      </div>
    </>
  );
}
