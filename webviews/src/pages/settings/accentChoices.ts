// The choices of appearance.accent with the color each gives the app theme, for the accent popup.
import { APP_ACCENTS, deriveAppTheme, type AppAccent, type TerminalColors } from "../../theme/appTheme";
import type { AccentChoice } from "./components/AccentPicker";
import type { SchemaRow } from "./schema";
import { text } from "./strings";

/** Art Color's value (Swift `AccentSetting.artID`): the hue of the art a window shows. */
export const ART_ACCENT = "art";

const isAppAccent = (value: string): value is AppAccent => (APP_ACCENTS as readonly string[]).includes(value);

/** Each schema choice of `row` (appearance.accent) with its swatch on `source`, the app theme's colors. */
export function accentChoices(row: SchemaRow, source: TerminalColors | undefined): AccentChoice[] {
  return (row.choices ?? []).map((choice) => ({
    value: choice.value,
    label: text(choice.title),
    art: choice.value === ART_ACCENT,
    swatch: source && isAppAccent(choice.value) ? deriveAppTheme(source, choice.value).tokens.accent : null,
  }));
}
