// l10n-allow-file: gallery-only contact sheet; state names are the format's ids, not shipped copy.
// The gallery's view of animated avatar sets: per set, every state live facing right and left,
// then the row's frames one by one, so a still capture shows the whole animation; then its look and
// drag rows the same way. `variants` compares the direction rows' alternatives side by side.
import { AnimatedAvatar } from "./AnimatedAvatar";
import { AVATAR_DIRECTIONS, AVATAR_MOTIONS, AVATAR_STATES, type AvatarMotion } from "./format";
import { AVATAR_SETS, avatarSet, type AvatarSet } from "./sets";
import { variantSet, type AvatarVariant } from "./variants";

export type AvatarSetSheetProps = {
  /** The sets to show, by id; default every built-in set. */
  ids?: readonly string[];
  /** `states`: every state and direction with its frames; `pick`: idle and working side by side, to
   * compare sets; `variants`: `motion`'s rows from the shipped sheet and each alternative. */
  view?: "states" | "pick" | "variants";
  size?: number;
  motion?: AvatarMotion;
  /** For `variants`: the alternatives to show after the shipped rows. */
  variants?: readonly AvatarVariant[];
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
          {AVATAR_MOTIONS.flatMap((motion) =>
            AVATAR_DIRECTIONS.map((toward) => {
              const spec = set.manifest.directions?.[motion]?.[toward];
              if (!spec) return null;
              return (
                <tr key={`${motion}-${toward}`} data-direction={`${motion}-${toward}`}>
                  <th scope="row">{`${motion} ${toward}`}</th>
                  <td>
                    <AnimatedAvatar set={set} motion={motion} toward={toward} size={size} />
                  </td>
                  <td>
                    <AnimatedAvatar set={set} motion={motion} toward={toward} facing="left" size={size} />
                  </td>
                  <td className="cmux-avatar-sheet-frames">
                    {Array.from({ length: spec.frames }, (_, frame) => (
                      <AnimatedAvatar
                        key={frame}
                        set={set}
                        motion={motion}
                        toward={toward}
                        frame={frame}
                        size={size / 2}
                      />
                    ))}
                  </td>
                </tr>
              );
            }),
          )}
        </tbody>
      </table>
    </section>
  );
}

/** One set's `motion` rows, a line per sheet (the shipped one, then each variant), live, toward each direction. */
function SetVariants({
  set,
  motion,
  variants,
  size,
}: {
  set: AvatarSet;
  motion: AvatarMotion;
  variants: readonly AvatarVariant[];
  size: number;
}) {
  const lines: [string, AvatarSet | undefined][] = [
    ["shipped", set],
    ...variants.map((variant): [string, AvatarSet | undefined] => [variant, variantSet(set.manifest.id, variant)]),
  ];
  return (
    <section className="cmux-avatar-sheet-set" data-set={set.manifest.id}>
      <h3>{`${set.manifest.name}: ${motion}`}</h3>
      <table>
        <thead>
          <tr>
            <th scope="col">variant</th>
            {AVATAR_DIRECTIONS.map((toward) => (
              <th key={toward} scope="col">
                {toward}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {lines.map(([name, drawn]) =>
            drawn ? (
              <tr key={name} data-variant={name}>
                <th scope="row">{name}</th>
                {AVATAR_DIRECTIONS.map((toward) => (
                  <td key={toward}>
                    <AnimatedAvatar set={drawn} motion={motion} toward={toward} size={size} />
                  </td>
                ))}
              </tr>
            ) : null,
          )}
        </tbody>
      </table>
    </section>
  );
}

export function AvatarSetSheet({
  ids,
  view = "states",
  size = 64,
  motion = "look",
  variants = [],
}: AvatarSetSheetProps) {
  const sets = ids ? ids.flatMap((id) => avatarSet(id) ?? []) : AVATAR_SETS;
  if (view === "variants")
    return (
      <div className="cmux-avatar-sheet" data-view={view}>
        {sets.map((set) => (
          <SetVariants key={set.manifest.id} set={set} motion={motion} variants={variants} size={size} />
        ))}
      </div>
    );
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
