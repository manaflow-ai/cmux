// The Labs section of the New Tab page (hq#1980), in team builds only (nightly and dev): every
// Labs flag as a row with its one-line intent and a toggle, so the team tries prototypes where
// they start work. A toggle asks the app to save `labs.<flag>`; the row follows `data-labs`, the
// app's answer. All Labs… opens Settings > Labs, the full list.
import { LABS_FLAGS, useLabsFlag, useLabsTeamBuild, type LabsFlagName } from "../../../experiments/labs";
import { useNt } from "./strings";

type Props = { onSet(flag: LabsFlagName, on: boolean): void; onShowAll(): void };

export function LabsList({ onSet, onShowAll }: Props) {
  const nt = useNt();
  if (!useLabsTeamBuild()) return null;
  return (
    <nav className="nt-open-tabs nt-labs" aria-label={nt("labs")}>
      <div className="nt-open-tabs-head">
        <span>{nt("labs")}</span>
        <button type="button" className="nt-chats-all" data-show-labs onClick={onShowAll}>
          {nt("labs.all")}
        </button>
      </div>
      {(Object.keys(LABS_FLAGS) as LabsFlagName[]).map((name) => (
        <LabRow key={name} name={name} onSet={onSet} />
      ))}
    </nav>
  );
}

function LabRow({ name, onSet }: { name: LabsFlagName; onSet: Props["onSet"] }) {
  const on = useLabsFlag(name);
  return (
    <label className="nt-row nt-lab" data-lab={name} title={`labs.${name}`}>
      <span className="nt-row-title">{LABS_FLAGS[name].intent}</span>
      <input type="checkbox" aria-label={LABS_FLAGS[name].intent} checked={on} onChange={() => onSet(name, !on)} />
    </label>
  );
}
