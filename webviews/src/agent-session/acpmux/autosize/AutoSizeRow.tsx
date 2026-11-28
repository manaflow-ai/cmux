import { usePaneLanguage, useT } from "../i18n";
import { autoSizeRowView, type AutoSizeRow as Row } from "./autosizeModel";
import "./autosize.css";
import { Button } from "../../../ui/Button";

/** How a row is drawn in the transcript; the gallery shows each so one can be picked. */
export type AutoSizeLook = "line" | "chip" | "card";

/// One AutoSize row in a Cloud chat's transcript: a notice from the computer, set apart from the
/// agent's turns. It reads a Rust-built row and adds no state; the upgrade button calls `onUpgrade`
/// with the plan (the app opens the plan's checkout).
export function AutoSizeRow({
  row,
  look = "line",
  onUpgrade,
}: {
  row: Row;
  look?: AutoSizeLook;
  onUpgrade?: (plan: string) => void;
}) {
  const t = useT();
  const lang = usePaneLanguage();
  const view = autoSizeRowView(row, t, lang);
  const plan = row.offer?.plan;
  const button =
    view.upgrade && plan && onUpgrade ? (
      <Button bare type="button" className="autosize-row-upgrade" onClick={() => onUpgrade(plan)}>
        {view.upgrade}
      </Button>
    ) : view.upgrade && plan ? (
      <Button bare type="button" className="autosize-row-upgrade" disabled>
        {view.upgrade}
      </Button>
    ) : null;
  return (
    <div
      className="autosize-row"
      data-look={look}
      data-kind={view.kind}
      data-autosize-key={row.key}
      role="note"
      aria-label={`${view.title}, ${view.why}`}
    >
      <span className="autosize-row-mark" aria-hidden="true" />
      <span className="autosize-row-body">
        <span className="autosize-row-title">{view.title}</span>
        <span className="autosize-row-why">{view.why}</span>
        <span className="autosize-row-rate">
          {view.rate}
          {view.change ? <span className="autosize-row-change"> {view.change}</span> : null}
        </span>
        {view.repeats ? <span className="autosize-row-repeats">{view.repeats}</span> : null}
      </span>
      {button}
    </div>
  );
}

/// A chat's AutoSize rows, oldest first, as Rust keeps them.
export function AutoSizeRows({
  rows,
  look,
  onUpgrade,
}: {
  rows: readonly Row[];
  look?: AutoSizeLook;
  onUpgrade?: (plan: string) => void;
}) {
  return (
    <div className="autosize-rows">
      {rows.map((row) => (
        <AutoSizeRow key={row.key} row={row} look={look} onUpgrade={onUpgrade} />
      ))}
    </div>
  );
}
