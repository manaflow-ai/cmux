// P4: a narrower scope's theme shows inline on the theme setting ("Overridden in this workspace by
// Dracula · Reset") instead of space/workspace/terminal tabs. The scopes are the host's theme
// levels of the active window; Reset runs the level's clear action (the palette's path).
import { useSettingsState, useStore } from "../context";
import { Icon } from "../icons";
import { t } from "../strings";

function overriddenText(level: string, theme: string): string | null {
  if (level === "room") return t("settingsPage.theme.overriddenSpace", theme);
  if (level === "workspace") return t("settingsPage.theme.overriddenWorkspace", theme);
  if (level === "terminal") return t("settingsPage.theme.overriddenTerminal", theme);
  return null;
}

export function ScopeOverrides() {
  const store = useStore();
  const { host, connected } = useSettingsState();
  const theme = host?.theme;
  if (!theme) return null;
  const overrides = theme.levels.flatMap((level) => {
    const name = theme.current[level];
    const label = name ? overriddenText(level, name) : null;
    return label ? [{ level, label }] : [];
  });
  return overrides.map(({ level, label }) => (
    <div className="row row-note" key={level} data-override={level}>
      <Icon name="layers" />
      <span className="row-note-text">{label}</span>
      <button
        type="button"
        className="link-button"
        disabled={!connected}
        onClick={() => void store.setTheme(level, null)}
      >
        {t("settingsPage.reset")}
      </button>
    </div>
  ));
}
