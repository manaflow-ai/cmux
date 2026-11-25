// A font row's pictures (fontPreviewModel.ts). Under a face choice: a tile per choice, its name and a
// specimen drawn in that face at the surface's size and line height; a click picks it, and moving the
// size or line height slider resizes every tile while it drags. Under a font family row: one sample of
// the picked family at its size. Leo, 2026-11-19: "idk i dont have pictures to see or sliders to adjust
// for the font".
import { useEffect, type CSSProperties } from "react";
import { useLiveValue, useRowState, useSettingsSelector, useStore } from "../context";
import { effectiveNumber } from "../inheritance";
import { rowsByKey, type SchemaRow } from "../schema";
import { t, text } from "../strings";
import {
  CODE_SPECIMEN,
  FONT_PREVIEWS,
  PREVIEW_INPUTS,
  TEXT_SPECIMEN,
  UI_SPECIMEN,
  familyStack,
  numberOr,
  type ChoicePreview,
  type FamilyPreview,
} from "../fontPreviewModel";

const NO_CHOICES: NonNullable<SchemaRow["choices"]> = [];

/** The value a number row draws at now: a slider's drag, else the stored or resolved value. */
function useNumber(key: string | null, fallback: number): number {
  const row = key ? rowsByKey.get(key) : undefined;
  const live = useLiveValue(key);
  const stored = useRowState(key ?? "").value;
  const effective = useSettingsSelector((state) => (row ? (effectiveNumber(state, row)?.value ?? null) : null));
  return numberOr(live ?? stored ?? effective, row?.range, fallback);
}

export function FontPreview({ row, value, disabled }: { row: SchemaRow; value: unknown; disabled: boolean }) {
  const preview = FONT_PREVIEWS[row.key];
  if (!preview) return null;
  return preview.kind === "choices" ? (
    <FontTiles row={row} preview={preview} value={value} disabled={disabled} />
  ) : (
    <FamilySample preview={preview} value={value} />
  );
}

function FontTiles({
  row,
  preview,
  value,
  disabled,
}: {
  row: SchemaRow;
  preview: ChoicePreview;
  value: unknown;
  disabled: boolean;
}) {
  const store = useStore();
  const size = useNumber(preview.size, 14);
  const lineHeight = useNumber(preview.lineHeight, 1.5);
  // The other keys a picture reads (PREVIEW_INPUTS): the Chat Font's System tile follows the Interface
  // Font, its Monospaced tile the configured code family, as the chat resolves them. One hook per key,
  // over a fixed list, so a change to any of them redraws the tiles.
  const inputs = [
    useRowState(PREVIEW_INPUTS[0]).value,
    useRowState(PREVIEW_INPUTS[1]).value,
    useRowState(PREVIEW_INPUTS[2]).value,
    useRowState(PREVIEW_INPUTS[3]).value,
    useRowState(PREVIEW_INPUTS[4]).value,
  ];
  const values = (key: string) => {
    const at = (PREVIEW_INPUTS as readonly string[]).indexOf(key);
    return at === -1 ? undefined : (inputs[at] ?? rowsByKey.get(key)?.default);
  };
  const current = value ?? row.default;
  // The schema row's own list: the same array every render, so the load below runs once per row.
  const choices = row.choices ?? NO_CHOICES;
  // Every bundled face loads once, when its picture first shows; until then the stack's next face draws.
  useEffect(() => {
    for (const choice of choices) void preview.load?.(choice.value).catch(() => undefined);
  }, [preview, choices]);
  return (
    <div
      className="font-tiles"
      data-font-tiles={row.key}
      // ui-allow: the font tiles are buttons in the ARIA radio pattern, as the density tiles are.
      role="radiogroup"
      aria-label={text(row.title)}
    >
      {choices.map((choice) => {
        const on = choice.value === current;
        const face = preview.face(choice.value, values);
        const style: CSSProperties = {
          fontFamily: face.family,
          letterSpacing: face.tracking,
          fontSize: `${size}px`,
          lineHeight: String(lineHeight),
        };
        return (
          <button
            // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- ui-allow: the ARIA radio pattern on a tile button, as DensityCard's tiles.
            role="radio"
            key={choice.value}
            type="button"
            aria-checked={on}
            className="font-tile"
            data-font-choice={choice.value}
            data-on={on ? "" : undefined}
            disabled={disabled}
            onClick={() => void (on ? undefined : store.set(row.key, choice.value))}
          >
            <span className="font-tile-picture" style={style} data-size={size} data-line-height={lineHeight}>
              <span className="font-tile-glyphs">{TEXT_SPECIMEN}</span>
              <span className="font-tile-line">{text(choice.title)}</span>
            </span>
            <span className="font-tile-name">
              {text(choice.title)}
              {on && <small>{t("settingsWindow.density.inUse")}</small>}
            </span>
          </button>
        );
      })}
    </div>
  );
}

function FamilySample({ preview, value }: { preview: FamilyPreview; value: unknown }) {
  const fallback = useRowState(preview.fallback ?? "").value;
  const size = useNumber(preview.size, 13);
  const name =
    typeof value === "string" && value ? value : preview.fallback && typeof fallback === "string" ? fallback : null;
  const specimen = preview.specimen ?? "code";
  return (
    <div className="font-sample" data-font-sample={name ?? ""} data-size={size} data-specimen={specimen}>
      <span style={{ fontFamily: familyStack(name, specimen), fontSize: `${size}px` }}>
        {specimen === "text" ? UI_SPECIMEN : CODE_SPECIMEN}
      </span>
    </div>
  );
}
