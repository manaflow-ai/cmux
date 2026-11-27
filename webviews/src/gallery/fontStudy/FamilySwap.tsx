// l10n-allow-file: type specimens and labels, gallery only, not shipped UI.
// The family swap (FamilySwap.gallery.ts): the same transcript lines drawn in one family, then, at each
// press of Swap family, in the next, so the stage's anchor check sees whether any line moved. Each line is
// one row that never wraps and keeps `line-height: normal` unless the variant sets one, so its height is
// the faces' own line box: the reply's serif, a code span in the mono inside it, a sidebar title in the
// sans, a code line, a display heading. A family whose faces disagree on the box moves every row under
// the first one that differs.
import { Fragment, useLayoutEffect, useRef, useState } from "react";
import { FACES, type FaceKey } from "./candidates";
import "./FamilySwap.css";

/// One family: a face (or a system stack) for each role.
export interface SwapFamily {
  label: string;
  sans: FaceKey | string;
  serif: FaceKey | string;
  display: FaceKey | string;
  mono: FaceKey | string;
  /** `font-variation-settings` for the whole sheet: unset by every gallery variant, so the cmux faces draw at their default `"WEFT" 0`. */
  variation?: string;
}

export interface FamilySwapProps {
  families: SwapFamily[];
  /** CSS px. */
  size?: number;
  /** `normal` (the faces' own box) or a unitless line height. */
  lineHeight?: "normal" | number;
}

const isFace = (value: string): value is FaceKey => value in FACES;
const stack = (value: string, generic: string) => (isFace(value) ? `"${FACES[value].family}", ${generic}` : value);

function Faces({ families }: { families: SwapFamily[] }) {
  const keys = new Set(families.flatMap((f) => [f.sans, f.serif, f.display, f.mono]).filter(isFace));
  const css = [...keys]
    .flatMap((key) => FACES[key].files.map((file) => [FACES[key].family, file] as const))
    .map(
      ([family, file]) =>
        `@font-face{font-family:"${family}";src:url(${file.url}) format("woff2");font-weight:${file.weight};font-style:normal;font-display:block}`,
    )
    .join("");
  return <style>{css}</style>;
}

/// The rows' tops relative to the sheet, after every commit: the readout says how far any row moved from
/// where the first family drew it. Layout is read once per family change, never per frame.
function useRowShift(index: number) {
  const sheet = useRef<HTMLDivElement>(null);
  const first = useRef<number[] | null>(null);
  const [shift, setShift] = useState<{ tops: number[]; max: number }>({ tops: [], max: 0 });
  useLayoutEffect(() => {
    const root = sheet.current;
    if (!root) return;
    const base = root.getBoundingClientRect().top;
    const tops = [...root.querySelectorAll<HTMLElement>("[data-swap-row]")].map(
      (row) => row.getBoundingClientRect().top - base,
    );
    // The first family's row tops, kept as the reference every later swap is measured against.
    // A plain check, not `??=`: the React Compiler cannot lower `??=` yet (React Doctor's react-hooks-js/todo).
    if (first.current === null) first.current = tops;
    const reference = first.current;
    const max = Math.max(0, ...tops.map((top, i) => Math.abs(top - (reference[i] ?? top))));
    setShift({ tops, max });
  }, [index]);
  return { sheet, shift };
}

export function FamilySwap({ families, size = 15, lineHeight = "normal" }: FamilySwapProps) {
  const [index, setIndex] = useState(0);
  const { sheet, shift } = useRowShift(index);
  const family = families[index % families.length];
  const sans = stack(family.sans, "system-ui, sans-serif");
  const serif = stack(family.serif, "ui-serif, serif");
  const display = stack(family.display, "ui-serif, serif");
  const mono = stack(family.mono, "ui-monospace, monospace");
  const rows: [string, React.ReactNode, React.CSSProperties][] = [
    [
      "reply",
      <>
        The retry test fails on CI because <code style={{ fontFamily: mono }}>sleep(200)</code> used real timers.
      </>,
      { fontFamily: serif },
    ],
    ["title", "Fix the retry test that only fails on CI under load", { fontFamily: sans }],
    [
      "mixed",
      <>
        <span style={{ fontFamily: sans }}>Edited </span>
        <code style={{ fontFamily: mono }}>retry.ts</code>
        <span style={{ fontFamily: serif }}> and its test, Il1| O0 — “3/4”.</span>
      </>,
      {},
    ],
    ["code", "await sleep(200 * 2 ** (attempt - 1)); // => != ===", { fontFamily: mono, fontSize: size * 0.875 }],
    ["display", "Quiet type, loud details", { fontFamily: display, fontSize: size * 2 }],
    ["after", "The next row: it moves when any row above it changes height.", { fontFamily: sans }],
  ];
  return (
    <div className="family-swap">
      <Faces families={families} />
      <div className="family-swap-bar">
        <button type="button" className="family-swap-button" onClick={() => setIndex((i) => i + 1)}>
          Swap family
        </button>
        <span className="family-swap-now" data-testid="family-swap-now">
          {family.label}
        </span>
        <span className="family-swap-shift" data-testid="family-swap-shift">
          Rows moved {shift.max.toFixed(2)} px since {families[0].label}
        </span>
      </div>
      <div
        ref={sheet}
        className="family-swap-sheet"
        style={{ fontFamily: sans, fontSize: size, lineHeight, fontVariationSettings: family.variation }}
      >
        {rows.map(([id, content, style], i) => (
          <Fragment key={id}>
            <div className="family-swap-row" data-swap-row={id} style={style}>
              {content}
            </div>
            <div className="family-swap-top">{shift.tops[i]?.toFixed(2) ?? ""}</div>
          </Fragment>
        ))}
      </div>
    </div>
  );
}
