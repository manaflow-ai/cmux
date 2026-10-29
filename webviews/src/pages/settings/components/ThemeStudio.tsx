// The Theme section (P3, P4): a full preview, then one card of rows. The terminal theme
// (`appearance.theme`) and the app theme (`appearance.appTheme`: match the terminal theme, or its own
// pick) each have Match System Appearance for a light and dark pair, and the accent
// (`appearance.accent`) is a swatch popup. Every theme choice is the same ThemePicker. The card also
// shows the contrast the derived app tokens reach and the active window's scope overrides inline
// (no space/workspace/terminal tabs). Overrides and the app theme are the host's theme levels. The
// schema's App Theme group lists the same keys; SectionView draws none of them a second time.
import { useCallback, useEffect, useId, useMemo, useRef, useState, type ReactNode } from "react";
import { ContextMenu, type ContextMenuItem } from "../../../ui/ContextMenu";
import { APP_ACCENTS, contrastReport, deriveAppTheme, type AppAccent } from "../../../theme/appTheme";
import type { GhosttyTheme } from "../../../theme/ghosttyTheme";
import {
  isEdited,
  themeEditKey,
  withAllEdits,
  type ThemeEditMap,
  type ThemeEditToken,
} from "../../../theme/themeEdits";
import { accentChoices } from "../accentChoices";
import { useColorScheme } from "../colorScheme";
import { useRowState, useSettingsState, useStore, type RowState } from "../context";
import { Switch } from "../editors/ToggleEditor";
import { Icon } from "../icons";
import { revealRow } from "../keyboard";
import { rowsByKey } from "../schema";
import { managedOf, valueOf } from "../store";
import { t, text } from "../strings";
import {
  configThemeColors,
  DEFAULT_DARK,
  DEFAULT_LIGHT,
  fallbackThemeName,
  terminalThemeColors,
} from "../themeDefaults";
import { formatThemeSpec, parseThemeSpec, themeFor, type ThemeSpec } from "../themeSpec";
import { AccentPicker } from "./AccentPicker";
import { ResetButton, ResetSpacer } from "./ResetButton";
import { ScopeOverrides } from "./ScopeOverrides";
import { RowFrame, RowStatus, SettingRow, useRowMenu } from "./SettingRow";
import { ThemeFiles } from "./ThemeFiles";
import { ThemeOverrides } from "./ThemeOverrides";
import { ThemePreview } from "./ThemePreview";
import { ThemePicker } from "./ThemePicker";
import { ThemeTokens } from "./ThemeTokens";

export const THEME_KEY = "appearance.theme";
/** The app theme apart from the terminal theme; `followTerminal` (its default) matches it. */
export const APP_THEME_KEY = "appearance.appTheme";
// appearance.themeEdits: per-token color edits, keyed "<theme>/<token>" (ThemeEditsSetting); drawn here, not as a row.
export const THEME_EDITS_KEY = "appearance.themeEdits";
/** appearance.accent: drawn here as the swatch popup, after the app theme. */
export const ACCENT_KEY = "appearance.accent";
const FOLLOW_TERMINAL = "followTerminal";

export function ThemeStudio({ focus = null }: { focus?: string | null } = {}) {
  const store = useStore();
  const state = useSettingsState();
  const scheme = useColorScheme();
  const ids = {
    theme: useId(),
    match: useId(),
    light: useId(),
    dark: useId(),
    app: useId(),
    appMatch: useId(),
    "app-light": useId(),
    "app-dark": useId(),
    accent: useId(),
  };
  const [previewing, setPreviewing] = useState<{ name: string; target: "terminal" | "app" } | null>(null);
  const load = useCallback((node: HTMLElement | null) => void (node && store.loadThemeColors()), [store]);

  const row = rowsByKey.get(THEME_KEY)!;
  const spec = parseThemeSpec(valueOf(state, THEME_KEY));
  const managed = managedOf(state, THEME_KEY);
  const disabled = !state.connected || !state.readable || managed !== null;
  const names = state.domains.themes;
  // Each theme with the user's edits (appearance.themeEdits): what the app shows for it.
  const edits = valueOf(state, THEME_EDITS_KEY) as ThemeEditMap | null;
  const colors = useMemo(() => withAllEdits(state.themeColors, edits), [state.themeColors, edits]);
  const custom = (name: string) => isEdited(edits, name);
  const editsManaged = managedOf(state, THEME_EDITS_KEY);
  // A token's live preview, at most every 80 ms: each one reloads the terminals' config.
  const pendingEdit = useRef<{ timer: ReturnType<typeof setTimeout> | null; next: ThemeEditMap | null }>({
    timer: null,
    next: null,
  });
  // Leaving the page with a token's tuner open ends its preview: the app goes back to what is saved.
  useEffect(
    () => () => {
      const pending = pendingEdit.current;
      if (pending.timer) clearTimeout(pending.timer);
      if (pending.timer || pending.next) store.previewEnd(THEME_EDITS_KEY);
    },
    [store],
  );
  const withEdit = (theme: string, token: ThemeEditToken, color: string | null): ThemeEditMap => {
    const next: Record<string, string> = { ...edits };
    if (color) next[themeEditKey(theme, token)] = color;
    else delete next[themeEditKey(theme, token)];
    return next;
  };
  const previewEdit = (theme: string, token: ThemeEditToken, color: string | null) => {
    const pending = pendingEdit.current;
    if (color === null) {
      if (pending.timer) clearTimeout(pending.timer);
      pending.timer = null;
      pending.next = null;
      store.previewEnd(THEME_EDITS_KEY);
      return;
    }
    pending.next = withEdit(theme, token, color);
    pending.timer ??= setTimeout(() => {
      pending.timer = null;
      if (pending.next) store.preview(THEME_EDITS_KEY, pending.next);
    }, 80);
  };
  const commitEdit = (theme: string, token: ThemeEditToken, color: string | null) => {
    const next = withEdit(theme, token, color);
    return Object.keys(next).length > 0 ? store.set(THEME_EDITS_KEY, next) : store.reset(THEME_EDITS_KEY);
  };
  const fallbackName = fallbackThemeName(scheme);
  // The Ghostty config's own colors, from the host while appearance.theme is unset.
  const configLabel = t("settingsWindow.themeUseConfig");
  const configColors = configThemeColors(state.host?.theme?.config, colors, scheme, configLabel);
  // appearance.appTheme: followTerminal (the default) or a theme apart from the terminal's.
  const appRow = rowsByKey.get(APP_THEME_KEY);
  const appValue = valueOf(state, APP_THEME_KEY);
  const appSpec = typeof appValue === "string" && appValue !== FOLLOW_TERMINAL ? parseThemeSpec(appValue) : null;
  const appManaged = managedOf(state, APP_THEME_KEY);
  // Right-click on a row's title: the same menu as every other setting row (cx-64hi).
  const themeMenu = useRowMenu(THEME_KEY);
  const appMenu = useRowMenu(APP_THEME_KEY);
  const accentMenu = useRowMenu(ACCENT_KEY);
  const appState = useRowState(APP_THEME_KEY);
  const appDisabled = !state.connected || !state.readable || appManaged !== null;
  const appPaired = appSpec?.kind === "pair";
  const appReset = (
    <ResetButton
      settingKey={APP_THEME_KEY}
      shown={appState.customized && !appManaged}
      disabled={!state.connected || !state.readable}
    />
  );
  const themeState = useRowState(THEME_KEY);
  const themeReset = (
    <ResetButton
      settingKey={THEME_KEY}
      shown={themeState.customized && !managed}
      disabled={!state.connected || !state.readable}
    />
  );
  const accentRow = rowsByKey.get(ACCENT_KEY);
  const accentState = useRowState(ACCENT_KEY);
  // The row `?focus=` names, once the owner's values arrive (before that every control is disabled),
  // revealed once: a row that mounts later (Match System Appearance swapping the rows) never takes
  // the focus back from the control just used.
  const revealed = useRef<string | null>(null);
  const focused = state.readable && focus !== revealed.current ? focus : null;
  const markRevealed = () => void (revealed.current = focus);
  // A route without `?focus=` forgets the revealed row, so Back to the same `?focus=` reveals it again.
  useEffect(() => {
    if (focus === null) revealed.current = null;
  }, [focus]);

  const lookup = (name: string | null): GhosttyTheme | undefined => (name ? colors?.get(name) : undefined);
  const terminal =
    previewing?.target === "terminal"
      ? lookup(previewing.name)
      : terminalThemeColors(valueOf(state, THEME_KEY), colors, scheme, configColors);
  const appSource =
    (previewing?.target === "app"
      ? lookup(previewing.name)
      : appSpec
        ? lookup(themeFor(appSpec, scheme, fallbackName))
        : undefined) ?? terminal;
  // The preview shows the accent the app uses; Art Color's hue comes from the art, so neutral here.
  const accentValue = typeof accentState.value === "string" ? accentState.value : "neutral";
  const accent: AppAccent = (APP_ACCENTS as readonly string[]).includes(accentValue)
    ? (accentValue as AppAccent)
    : "neutral";
  const app = appSource ? deriveAppTheme(appSource, accent) : null;
  const accents = useMemo(() => (accentRow ? accentChoices(accentRow, appSource) : []), [accentRow, appSource]);

  const write = (next: ThemeSpec | null) =>
    next ? store.set(THEME_KEY, formatThemeSpec(next)) : store.reset(THEME_KEY);
  const previewTerminal = (name: string | null) => {
    setPreviewing(name ? { name, target: "terminal" } : null);
    if (name) store.preview(THEME_KEY, name);
    else store.previewEnd(THEME_KEY);
  };
  const writeApp = (next: ThemeSpec | null) =>
    next ? store.set(APP_THEME_KEY, formatThemeSpec(next)) : store.reset(APP_THEME_KEY);
  const appPicker = (
    id: string,
    value: string | null,
    nullChoice: boolean,
    onPick: (name: string | null) => void | Promise<unknown>,
  ) => (
    <ThemePicker
      value={value}
      names={names}
      colors={colors}
      labelId={id}
      disabled={appDisabled}
      configLabel={text(appRow?.default_label) || t("settingsPage.theme.matchTerminal")}
      configColors={terminal}
      nullChoice={nullChoice}
      onPick={onPick}
      onPreview={previewApp}
      custom={custom}
    />
  );
  const previewApp = (name: string | null) => {
    setPreviewing(name ? { name, target: "app" } : null);
    if (name) store.preview(APP_THEME_KEY, name);
    else store.previewEnd(APP_THEME_KEY);
  };
  const paired = spec?.kind === "pair";
  const current = (side: "light" | "dark") => (spec ? themeFor(spec, side, fallbackName) : null);
  const picker = (id: string, value: string | null, onPick: (name: string | null) => void | Promise<unknown>) => (
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
      custom={custom}
    />
  );
  const pickSide = (side: "light" | "dark") => (name: string | null) => {
    const other = side === "light" ? "dark" : "light";
    const keep = current(other) ?? (other === "light" ? DEFAULT_LIGHT : DEFAULT_DARK);
    const chosen = name ?? (side === "light" ? DEFAULT_LIGHT : DEFAULT_DARK);
    return write({ kind: "pair", light: side === "light" ? chosen : keep, dark: side === "dark" ? chosen : keep });
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
          <ThemeTokens
            theme={terminal}
            base={state.themeColors?.get(terminal.name) ?? terminal}
            edits={edits}
            others={state.themeColors?.values() ?? []}
            editable={
              !disabled && editsManaged === null && previewing === null && !!state.themeColors?.has(terminal.name)
            }
            onPreview={(token, color) => previewEdit(terminal.name, token, color)}
            onCommit={(token, color) => commitEdit(terminal.name, token, color)}
          />
          <figcaption className="theme-caption">
            <span className="theme-caption-name">{terminal.name}</span>
            <span className="theme-caption-contrast" data-contrast="">
              <Icon name="check" />
              {t("settingsPage.theme.contrast", lowest("text"), lowest("textSecondary"), lowest("accent"))}
            </span>
          </figcaption>
          <ThemeFiles
            base={terminal.name}
            disabled={disabled || previewing !== null}
            canSave={!!state.themeColors?.has(terminal.name)}
            onSaved={(name) => (paired ? pickSide(scheme)(name) : write({ kind: "single", name }))}
          />
        </figure>
      ) : null}
      <ThemeOverrides disabled={!state.connected} />
      <section className="group" data-theme-rows="">
        <div className="rows">
          {names.length === 0 ? (
            // The app published no theme names: the plain setting row (a text field for the spec).
            <SettingRow row={row} focused={focused === THEME_KEY} />
          ) : (
            <>
              <StudioRow
                kind="match"
                settingKey={THEME_KEY}
                state={themeState}
                id={ids.match}
                title={t("settingsPage.theme.matchSystem")}
                help={t("settingsPage.theme.matchSystemHelp")}
                menu={themeMenu}
                reset={<ResetSpacer />}
              >
                <Switch
                  checked={paired}
                  disabled={disabled}
                  labelId={ids.match}
                  onToggle={(on) => void write(toggledPair(spec, on, scheme, fallbackName))}
                />
              </StudioRow>
              {paired ? (
                (["light", "dark"] as const).map((side) => (
                  <StudioRow
                    key={side}
                    kind={side}
                    settingKey={THEME_KEY}
                    reveal={side === "light" && focused === THEME_KEY}
                    onRevealed={markRevealed}
                    id={ids[side]}
                    title={side === "light" ? t("settingsPage.theme.light") : t("settingsPage.theme.dark")}
                    menu={themeMenu}
                    reset={side === "light" ? themeReset : <ResetSpacer />}
                  >
                    {picker(ids[side], current(side), pickSide(side))}
                  </StudioRow>
                ))
              ) : (
                <StudioRow
                  kind="single"
                  settingKey={THEME_KEY}
                  reveal={focused === THEME_KEY}
                  onRevealed={markRevealed}
                  id={ids.theme}
                  title={t("settingsPage.theme.terminal")}
                  help={t("settingsPage.theme.terminalHelp")}
                  menu={themeMenu}
                  reset={themeReset}
                >
                  {picker(ids.theme, spec?.kind === "single" ? spec.name : null, (name) =>
                    write(name ? { kind: "single", name } : null),
                  )}
                </StudioRow>
              )}
            </>
          )}
          <ScopeOverrides />
          {appRow && names.length === 0 && <SettingRow row={appRow} focused={focused === APP_THEME_KEY} />}
          {appRow && names.length > 0 && (
            <>
              <StudioRow
                kind="app-match"
                settingKey={APP_THEME_KEY}
                state={appState}
                id={ids.appMatch}
                title={t("settingsPage.theme.matchSystem")}
                help={appSpec ? t("settingsPage.theme.matchSystemHelp") : t("settingsPage.theme.appFollowsTerminal")}
                menu={appMenu}
                reset={<ResetSpacer />}
              >
                {/* While the app theme matches the terminal theme it follows the terminal's switch. */}
                <Switch
                  checked={appSpec ? appPaired : paired}
                  disabled={appDisabled || !appSpec}
                  labelId={ids.appMatch}
                  onToggle={(on) => void writeApp(toggledPair(appSpec, on, scheme, fallbackName))}
                />
              </StudioRow>
              {appSpec?.kind === "pair" ? (
                (["light", "dark"] as const).map((side) => (
                  <StudioRow
                    key={side}
                    kind={`app-${side}`}
                    settingKey={APP_THEME_KEY}
                    reveal={side === "light" && focused === APP_THEME_KEY}
                    onRevealed={markRevealed}
                    id={ids[`app-${side}`]}
                    title={side === "light" ? t("settingsPage.theme.light") : t("settingsPage.theme.dark")}
                    menu={appMenu}
                    reset={side === "light" ? appReset : <ResetSpacer />}
                  >
                    {appPicker(ids[`app-${side}`], appSpec[side], false, (name) =>
                      name
                        ? writeApp(side === "light" ? { ...appSpec, light: name } : { ...appSpec, dark: name })
                        : undefined,
                    )}
                  </StudioRow>
                ))
              ) : (
                <StudioRow
                  kind="app"
                  settingKey={APP_THEME_KEY}
                  reveal={focused === APP_THEME_KEY}
                  onRevealed={markRevealed}
                  id={ids.app}
                  title={t("settingsPage.theme.app")}
                  help={text(appRow.summary)}
                  menu={appMenu}
                  reset={appReset}
                >
                  {appPicker(ids.app, appSpec?.kind === "single" ? appSpec.name : null, true, (name) =>
                    writeApp(name ? { kind: "single", name } : null),
                  )}
                </StudioRow>
              )}
            </>
          )}
          {accentRow && (
            <StudioRow
              kind="accent"
              settingKey={ACCENT_KEY}
              reveal={focused === ACCENT_KEY}
              onRevealed={markRevealed}
              id={ids.accent}
              title={text(accentRow.title)}
              help={text(accentRow.summary)}
              state={accentState}
              menu={accentMenu}
              reset={
                <ResetButton
                  settingKey={ACCENT_KEY}
                  shown={accentState.customized && !accentState.managed}
                  disabled={!accentState.connected || !accentState.readable}
                />
              }
            >
              <AccentPicker
                value={typeof accentState.value === "string" ? accentState.value : String(accentRow.default ?? "")}
                choices={accents}
                labelId={ids.accent}
                label={text(accentRow.title)}
                disabled={!accentState.connected || !accentState.readable || accentState.managed !== null}
                onPick={(next) => (next === accentRow.default ? store.reset(ACCENT_KEY) : store.set(ACCENT_KEY, next))}
              />
            </StudioRow>
          )}
        </div>
      </section>
    </div>
  );
}

/** Match System Appearance turned on or off: a pair from the theme in effect (the other side the
 * default of that side), or the single theme in effect. */
export function toggledPair(
  spec: ThemeSpec | null,
  on: boolean,
  scheme: "light" | "dark",
  fallback: string,
): ThemeSpec {
  const name = themeFor(spec, scheme, fallback);
  if (!on) return { kind: "single", name };
  return {
    kind: "pair",
    light: scheme === "light" ? name : DEFAULT_LIGHT,
    dark: scheme === "dark" ? name : DEFAULT_DARK,
  };
}

/** One row of the Theme section: title and help on the left, the control and the row's reserved
 * Reset slot on the right, the same layout as every SettingRow. */
function StudioRow({
  kind,
  settingKey,
  state,
  reveal = false,
  onRevealed,
  id,
  title,
  help,
  menu,
  reset,
  children,
}: {
  kind: string;
  /** The key it edits: Up/Down, the Reset command and `?focus=` treat it as that setting's row. */
  settingKey: string;
  /** The key's state, on the key's first row only: its settings-file notice, why it is managed and
   * why its last write failed, as on every SettingRow. */
  state?: RowState;
  /** The row `?focus=` names: scrolled to with its control focused. */
  reveal?: boolean;
  onRevealed?(): void;
  id: string;
  title: string;
  help?: string;
  menu: ContextMenuItem[];
  reset: ReactNode;
  children: ReactNode;
}) {
  return (
    <RowFrame
      settingKey={settingKey}
      kind={rowsByKey.get(settingKey)?.kind ?? "theme"}
      state={state}
      data-theme-row={kind}
      rowRef={
        reveal
          ? (node: HTMLDivElement | null) => {
              if (!node) return;
              revealRow(node);
              onRevealed?.();
            }
          : undefined
      }
    >
      <div className="row-main">
        <ContextMenu className="row-label" items={menu}>
          <div className="row-title" id={id}>
            {title}
          </div>
          {help && <div className="row-help">{help}</div>}
          {state && <RowStatus settingKey={settingKey} state={state} />}
        </ContextMenu>
        <div className="row-control">
          {children}
          {reset}
        </div>
      </div>
    </RowFrame>
  );
}
