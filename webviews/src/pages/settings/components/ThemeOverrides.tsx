// The Theme section's notice: colors the person's Ghostty config sets itself (`background = …`).
// Ghostty applies the config over the theme, so no theme can change them while the lines stay.
// It names the keys and their lines, and Let Themes Set Colors turns those lines into comments
// (the host keeps the old values in the file). Data: the host lists' `theme_overrides`, live
// through cmux.settings.host.changed.
import { useState } from "react";
import { useSettingsState, useStore } from "../context";
import { Icon } from "../icons";
import type { ThemeOverride } from "../ops";
import { locale, t } from "../strings";

/** "background and foreground" in the page's language. */
function keyList(overrides: ThemeOverride[]): string {
  const keys = [...new Set(overrides.map((override) => override.key))];
  return new Intl.ListFormat(locale(), { type: "conjunction" }).format(keys);
}

/** One "~/.config/ghostty/config, lines 2, 3" per file, in load order. */
function sources(overrides: ThemeOverride[]): string[] {
  const lines = new Map<string, number[]>();
  for (const override of overrides) lines.set(override.file, [...(lines.get(override.file) ?? []), override.line]);
  return [...lines].map(([file, numbers]) => {
    const sorted = [...numbers].sort((a, b) => a - b).join(", ");
    return t(
      numbers.length === 1 ? "settingsPage.theme.overrides.line" : "settingsPage.theme.overrides.lines",
      file,
      sorted,
    );
  });
}

export function ThemeOverrides({ disabled }: { disabled: boolean }) {
  const store = useStore();
  const { host } = useSettingsState();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const overrides = host?.theme_overrides ?? [];
  if (overrides.length === 0) return null;
  const release = async () => {
    setBusy(true);
    try {
      const reply = await store.releaseThemeOverrides();
      setError(reply.ok ? null : reply.error.message);
    } finally {
      setBusy(false);
    }
  };
  return (
    <output className="theme-overrides" data-theme-overrides="">
      <Icon name="warning" />
      <div className="theme-overrides-body">
        <div className="theme-overrides-text">
          <span>{t("settingsPage.theme.overrides.message", keyList(overrides))}</span>
          {sources(overrides).map((source) => (
            <span key={source} className="theme-overrides-source selectable">
              {source}
            </span>
          ))}
          {error && <span className="theme-overrides-error">{error}</span>}
        </div>
        <div className="theme-overrides-actions">
          <button
            type="button"
            className="button"
            disabled={disabled || busy}
            title={t("settingsPage.theme.overrides.releaseHelp")}
            data-theme-overrides-action="release"
            onClick={() => void release()}
          >
            {t("settingsPage.theme.overrides.release")}
          </button>
          <button
            type="button"
            className="link-button"
            data-theme-overrides-action="open"
            onClick={() => store.openThemeOverrides()}
          >
            {t("settingsPage.theme.overrides.open")}
          </button>
        </div>
      </div>
    </output>
  );
}
