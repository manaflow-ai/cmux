// l10n-allow-file: gallery-only contact sheet; state names are the format's ids, not shipped copy.
// The gallery's view of animated avatar sets: per set, every state live facing right and left,
// then the row's frames one by one, so a still capture shows the whole animation.
import { AnimatedAvatar } from "./AnimatedAvatar";
import { AVATAR_STATES } from "./format";
import { AVATAR_SETS, avatarSet, type AvatarSet } from "./sets";

export type AvatarSetSheetProps = {
  /** The sets to show, by id; default every built-in set. */
  ids?: readonly string[];
  /** `states`: every state with its frames; `pick`: idle and working side by side, to compare sets. */
  view?: "states" | "pick";
  size?: number;
};

function SetStates({ set, size }: { set: AvatarSet; size: number }) {
  return (
    <section className="cmux-avatar-sheet-set" data-set={set.manifest.id}>
      <h3>{set.manifest.name}</h3>
      <table>
        <tbody>
          {AVATAR_STATES.map((state) => {
            const spec = set.manifest.states[state];
            return (
              <tr key={state} data-state={state}>
                <th scope="row">{state}</th>
                <td>
                  <AnimatedAvatar set={set} state={state} size={size} label={`${set.manifest.name} ${state}`} />
                </td>
                <td>
                  <AnimatedAvatar set={set} state={state} facing="left" size={size} />
                </td>
                <td className="cmux-avatar-sheet-frames">
                  {Array.from({ length: spec?.frames ?? 0 }, (_, frame) => (
                    <AnimatedAvatar key={frame} set={set} state={state} frame={frame} size={size / 2} />
                  ))}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </section>
  );
}

export function AvatarSetSheet({ ids, view = "states", size = 64 }: AvatarSetSheetProps) {
  const sets = ids ? ids.flatMap((id) => avatarSet(id) ?? []) : AVATAR_SETS;
  return (
    <div className="cmux-avatar-sheet" data-view={view}>
      {view === "pick"
        ? sets.map((set) => (
            <figure key={set.manifest.id} data-set={set.manifest.id}>
              <AnimatedAvatar set={set} size={size} still />
              <AnimatedAvatar set={set} state="working" size={size} />
              <AnimatedAvatar set={set} state="waiting" facing="left" size={size} />
              <figcaption>{set.manifest.name}</figcaption>
            </figure>
          ))
        : sets.map((set) => <SetStates key={set.manifest.id} set={set} size={size} />)}
    </div>
  );
}
