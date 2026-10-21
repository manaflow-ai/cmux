import { useEffect, useMemo } from "react";
import type { GhosttyTheme } from "../../../theme/ghosttyTheme";
import { withAllEdits, type ThemeEditMap } from "../../../theme/themeEdits";
import { accentChoices } from "../accentChoices";
import { AccentPicker } from "../components/AccentPicker";
import { useColorScheme } from "../colorScheme";
import { useSettingsSelector, useStore } from "../context";
import { valueOf } from "../store";
import { text } from "../strings";
import { parseThemeSpec, themeFor } from "../themeSpec";
import type { EditorProps } from "./types";

/** The theme the app takes its tokens from: appearance.appTheme's, else the terminal theme's. */
function appSourceName(theme: unknown, appTheme: unknown, side: "dark" | "light"): string | null {
  const app = typeof appTheme === "string" && appTheme !== "followTerminal" ? parseThemeSpec(appTheme) : null;
  const spec = app ?? parseThemeSpec(theme);
  return spec ? themeFor(spec, side, "") || null : null;
}

/**
 * appearance.accent outside the Theme section (search results): the Theme section's swatch popup,
 * its swatches on the app theme in effect (the Ghostty config's colors while no theme is set).
 */
export function AccentRowEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const side = useColorScheme();
  const name = useSettingsSelector((state) =>
    appSourceName(valueOf(state, "appearance.theme"), valueOf(state, "appearance.appTheme"), side),
  );
  const themeColors = useSettingsSelector((state) => state.themeColors);
  const edits = useSettingsSelector((state) => valueOf(state, "appearance.themeEdits") as ThemeEditMap | null);
  const config = useSettingsSelector((state) => state.host?.theme?.config ?? null);
  useEffect(() => void store.loadThemeColors(), [store]);
  const source: GhosttyTheme | undefined = useMemo(() => {
    const colors = withAllEdits(themeColors, edits);
    return (name ? colors?.get(name) : undefined) ?? config ?? undefined;
  }, [name, themeColors, edits, config]);
  const choices = useMemo(() => accentChoices(row, source), [row, source]);
  const current = typeof value === "string" ? value : String(row.default ?? "");
  return (
    <AccentPicker
      value={current}
      choices={choices}
      labelId={labelId}
      label={text(row.title)}
      disabled={disabled}
      onPick={(next) => (next === row.default ? store.reset(row.key) : store.set(row.key, next))}
    />
  );
}
