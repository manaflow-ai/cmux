// The Theme section (P3, P4): one picker over every bundled Ghostty theme with a full preview, a
// light and dark pair that follows the system, the app theme (match the terminal theme, or any
// bundled theme), the contrast the derived app tokens reach, and the scope overrides of the
// active window inline on the setting (no space/workspace/terminal tabs). The theme value stays
// `appearance.theme`; overrides and the app theme are the host's theme levels.
import { useCallback, useId, useState, useSyncExternalStore } from "react";
import { ContextMenu } from "../../../ui/ContextMenu";
import { contrastReport, deriveAppTheme } from "../../../theme/appTheme";
import type { GhosttyTheme } from "../../../theme/ghosttyTheme";
import { useSettingsState, useStore } from "../context";
import { Switch } from "../editors/ToggleEditor";
import { Icon } from "../icons";
import { rowsByKey } from "../schema";
import { managedOf, managedText, valueOf } from "../store";
import { t, text } from "../strings";
import { formatThemeSpec, parseThemeSpec, themeFor, type ThemeSpec } from "../themeSpec";
import { ScopeOverrides } from "./ScopeOverrides";
import { SettingRow, useRowMenu } from "./SettingRow";
import { ThemePalette, ThemePreview } from "./ThemePreview";
import { ThemePicker } from "./ThemePicker";

export const THEME_KEY = "appearance.theme";
/** The app theme apart from the terminal theme; `followTerminal` (its default) matches it. */
export const APP_THEME_KEY = "appearance.appTheme";
const FOLLOW_TERMINAL = "followTerminal";
const DEFAULT_DARK = "Apple System Colors";
const DEFAULT_LIGHT = "Apple System Colors Light";

const darkQuery = "(prefers-color-scheme: dark)";
function subscribeScheme(onChange: () => void): () => void {
  const query = window.matchMedia?.(darkQuery);
  query?.addEventListener("change", onChange);
  return () => query?.removeEventListener("change", onChange);
}
const readScheme = (): "dark" | "light" => (window.matchMedia?.(darkQuery).matches ? "dark" : "light");

/** The system appearance the page is shown in (the app's, through WebKit). */
function useColorScheme(): "dark" | "light" {
  return useSyncExternalStore(subscribeScheme, readScheme, () => "dark");
}

export function ThemeStudio() {
  const store = useStore();
  const state = useSettingsState();
  const scheme = useColorScheme();
  const ids = { theme: useId(), match: useId(), light: useId(), dark: useId(), app: useId() };
  const [previewing, setPreviewing] = useState<{ name: string; target: "terminal" | "app" } | null>(null);
  const load = useCallback((node: HTMLElement | null) => void (node && store.loadThemeColors()), [store]);

  const row = rowsByKey.get(THEME_KEY)!;
  const spec = parseThemeSpec(valueOf(state, THEME_KEY));
  const managed = managedOf(state, THEME_KEY);
  const disabled = !state.connected || !state.readable || managed !== null;
  const names = state.domains.themes;
  const colors = state.themeColors;
  const fallbackName = scheme === "dark" ? DEFAULT_DARK : DEFAULT_LIGHT;
  // The Ghostty config's own colors, from the host while appearance.theme is unset.
  const configLabel = t("settingsWindow.themeUseConfig");
  const configColors: GhosttyTheme | undefined = state.host?.theme?.config
    ? { ...state.host.theme.config, name: configLabel }
    : colors?.get(fallbackName);
  // appearance.appTheme: followTerminal (the default) or a theme apart from the terminal's.
  const appRow = rowsByKey.get(APP_THEME_KEY);
  const appValue = valueOf(state, APP_THEME_KEY);
  const appSpec = typeof appValue === "string" && appValue !== FOLLOW_TERMINAL ? parseThemeSpec(appValue) : null;
  const appManaged = managedOf(state, APP_THEME_KEY);
  // Right-click on a row's title: the same menu as every other setting row (cx-64hi).
  const themeMenu = useRowMenu(THEME_KEY);
  const appMenu = useRowMenu(APP_THEME_KEY);

  const lookup = (name: string | null): GhosttyTheme | undefined => (name ? colors?.get(name) : undefined);
  const terminal =
    previewing?.target === "terminal"
      ? lookup(previewing.name)
      : spec
        ? (lookup(themeFor(spec, scheme, fallbackName)) ?? configColors)
        : configColors;
  const appSource =
    (previewing?.target === "app"
      ? lookup(previewing.name)
      : appSpec
        ? lookup(themeFor(appSpec, scheme, fallbackName))
        : undefined) ?? terminal;
  const app = appSource ? deriveAppTheme(appSource) : null;

  const write = (next: ThemeSpec | null) => {
    if (next) void store.set(THEME_KEY, formatThemeSpec(next));
    else void store.reset(THEME_KEY);
  };
  const previewTerminal = (name: string | null) => {
    setPreviewing(name ? { name, target: "terminal" } : null);
    if (name) store.preview(THEME_KEY, name);
    else store.previewEnd(THEME_KEY);
  };
  const paired = spec?.kind === "pair";
  const current = (side: "light" | "dark") => (spec ? themeFor(spec, side, fallbackName) : null);
  const picker = (id: string, value: string | null, onPick: (name: string | null) => void) => (
    <ThemePicker
      value={value}
      names={names}
      colors={colors}
      labelId={id}
      disabled={disabled}
      configLabel={configLabel}
      configColors={configColors}
      onPick={onPick}
      onPreview={previewTerminal}
    />
  );
  const pickSide = (side: "light" | "dark") => (name: string | null) => {
    const other = side === "light" ? "dark" : "light";
    const keep = current(other) ?? (other === "light" ? DEFAULT_LIGHT : DEFAULT_DARK);
    const chosen = name ?? (side === "light" ? DEFAULT_LIGHT : DEFAULT_DARK);
    write({ kind: "pair", light: side === "light" ? chosen : keep, dark: side === "dark" ? chosen : keep });
  };
  const report = app ? contrastReport(app) : [];
  const lowest = (token: string) =>
    Math.min(...report.filter((pair) => pair.token === token).map((pair) => pair.ratio)).toFixed(1);

  return (
    <div className="theme-studio" ref={load} data-card="theme">
      {terminal && app ? (
        <figure className="theme-hero">
          <ThemePreview
            theme={terminal}
            app={app}
            fontFamily={(valueOf(state, "terminal.fontFamily") as string | null) ?? null}
            label={t("settingsPage.theme.previewOf", terminal.name)}
          />
          <ThemePalette theme={terminal} separator={app.tokens.separator} />
          <figcaption className="theme-caption">
            <span className="theme-caption-name">{terminal.name}</span>
            <span className="theme-caption-contrast" data-contrast="">
              <Icon name="check" />
              {t("settingsPage.theme.contrast", lowest("text"), lowest("textSecondary"), lowest("accent"))}
            </span>
          </figcaption>
        </figure>
      ) : null}
      <section className="group">
        <h3 className="group-title">{t("settingsPage.theme.terminal")}</h3>
        <div className="rows">
          {names.length === 0 ? (
            // The app published no theme names: the plain setting row (a text field for the spec).
            <SettingRow row={row} />
          ) : (
            <>
              <div className="row" data-theme-row="match">
                <div className="row-main">
                  <ContextMenu className="row-label" items={themeMenu}>
                    <div className="row-title" id={ids.match}>
                      {t("settingsPage.theme.matchSystem")}
                    </div>
                    <div className="row-help">{t("settingsPage.theme.matchSystemHelp")}</div>
                  </ContextMenu>
                  <div className="row-control">
                    <Switch
                      checked={paired}
                      disabled={disabled}
                      labelId={ids.match}
                      onToggle={(on) => {
                        const name = themeFor(spec, scheme, fallbackName);
                        if (on)
                          write({
                            kind: "pair",
                            light: scheme === "light" ? name : DEFAULT_LIGHT,
                            dark: scheme === "dark" ? name : DEFAULT_DARK,
                          });
                        else write({ kind: "single", name });
                      }}
                    />
                  </div>
                </div>
              </div>
              {paired ? (
                (["light", "dark"] as const).map((side) => (
                  <div className="row" key={side} data-theme-row={side}>
                    <div className="row-main">
                      <ContextMenu className="row-label" items={themeMenu}>
                        <div className="row-title" id={ids[side]}>
                          {side === "light" ? t("settingsPage.theme.light") : t("settingsPage.theme.dark")}
                        </div>
                      </ContextMenu>
                      <div className="row-control">{picker(ids[side], current(side), pickSide(side))}</div>
                    </div>
                  </div>
                ))
              ) : (
                <div className="row" data-theme-row="single">
                  <div className="row-main">
                    <ContextMenu className="row-label" items={themeMenu}>
                      <div className="row-title" id={ids.theme}>
                        {text(row.title)}
                      </div>
                      <div className="row-help">{t("settingsPage.theme.terminalHelp", names.length)}</div>
                    </ContextMenu>
                    <div className="row-control">
                      {picker(ids.theme, spec?.kind === "single" ? spec.name : null, (name) =>
                        write(name ? { kind: "single", name } : null),
                      )}
                    </div>
                  </div>
                </div>
              )}
            </>
          )}
          {managed && names.length > 0 && (
            <div className="row row-note" data-managed-reason="">
              <Icon name="lock" />
              {managedText(managed)}
            </div>
          )}
          <ScopeOverrides />
        </div>
      </section>
      {appRow && (
        <section className="group" data-theme-app="">
          <h3 className="group-title">{t("settingsPage.theme.app")}</h3>
          <div className="rows">
            <div className="row" data-theme-row="app">
              <div className="row-main">
                <ContextMenu className="row-label" items={appMenu}>
                  <div className="row-title" id={ids.app}>
                    {text(row.title)}
                  </div>
                  <div className="row-help">{text(appRow.help)}</div>
                  {appManaged && (
                    <div className="row-managed" data-managed-reason="">
                      <Icon name="lock" />
                      {managedText(appManaged)}
                    </div>
                  )}
                </ContextMenu>
                <div className="row-control">
                  <ThemePicker
                    value={appSpec ? formatThemeSpec(appSpec) : null}
                    names={names}
                    colors={colors}
                    labelId={ids.app}
                    disabled={!state.connected || !state.readable || appManaged !== null}
                    configLabel={text(appRow.default_label) || t("settingsPage.theme.matchTerminal")}
                    configColors={terminal}
                    onPick={(name) => void (name ? store.set(APP_THEME_KEY, name) : store.reset(APP_THEME_KEY))}
                    onPreview={(name) => setPreviewing(name ? { name, target: "app" } : null)}
                  />
                </div>
              </div>
            </div>
          </div>
        </section>
      )}
    </div>
  );
}
