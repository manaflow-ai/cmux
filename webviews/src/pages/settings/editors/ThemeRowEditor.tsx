import { useEffect, useMemo } from "react";
import { withAllEdits, isEdited, type ThemeEditMap } from "../../../theme/themeEdits";
import { useColorScheme } from "../colorScheme";
import { useSettingsSelector, useStore } from "../context";
import { ThemePicker } from "../components/ThemePicker";
import { valueOf } from "../store";
import { t, text } from "../strings";
import { configThemeColors, terminalThemeColors } from "../themeDefaults";
import { formatThemeSpec, parseThemeSpec, themeFor, type ThemeSpec } from "../themeSpec";
import { TextEditor } from "./TextEditor";
import type { EditorProps } from "./types";

const THEME_EDITS_KEY = "appearance.themeEdits";
const THEME_KEY = "appearance.theme";

/**
 * A `theme` row outside the Theme section (search results): the Theme section's own picker, so a
 * theme is chosen the same way everywhere. A light/dark pair shows and replaces the side in effect;
 * the Theme section edits both sides. With no published names, a text field for the spec.
 */
export function ThemeRowEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const side = useColorScheme();
  const names = useSettingsSelector((state) => state.domains.themes);
  // Only the theme colors and the color edits: another key's change never re-renders this row.
  const themeColors = useSettingsSelector((state) => state.themeColors);
  const edits = useSettingsSelector((state) => valueOf(state, THEME_EDITS_KEY) as ThemeEditMap | null);
  useEffect(() => void store.loadThemeColors(), [store]);
  const colors = useMemo(() => withAllEdits(themeColors, edits), [themeColors, edits]);
  // The default choice's swatch, as the Theme card draws it: the Ghostty config's colors on the
  // terminal theme, the terminal's resolved theme on the app theme.
  const config = useSettingsSelector((state) => state.host?.theme?.config ?? null);
  const terminalValue = useSettingsSelector((state) => valueOf(state, THEME_KEY));
  const configLabel = text(row.default_label) || t("settingsWindow.themeUseConfig");
  const configColors = useMemo(() => {
    const ghostty = configThemeColors(config, colors, side, t("settingsWindow.themeUseConfig"));
    return row.key === THEME_KEY ? ghostty : terminalThemeColors(terminalValue, colors, side, ghostty);
  }, [config, colors, side, row.key, terminalValue]);
  if (names.length === 0) return <TextEditor row={row} value={value} disabled={disabled} labelId={labelId} />;
  const spec = typeof value === "string" && value !== row.default ? parseThemeSpec(value) : null;
  const current = spec ? themeFor(spec, side, "") || null : null;
  return (
    <ThemePicker
      value={current}
      names={names}
      colors={colors}
      labelId={labelId}
      disabled={disabled}
      configLabel={configLabel}
      configColors={configColors}
      custom={(name) => isEdited(edits, name)}
      // A light/dark pair keeps its other side: the pick replaces the side in effect.
      onPick={(name) => {
        if (!name) return store.reset(row.key);
        const next: ThemeSpec =
          spec?.kind !== "pair"
            ? { kind: "single", name }
            : side === "light"
              ? { ...spec, light: name }
              : { ...spec, dark: name };
        return store.set(row.key, formatThemeSpec(next));
      }}
      onPreview={(name, owner) => (name ? store.preview(row.key, name, owner) : store.previewEnd(row.key, owner))}
    />
  );
}
