// The Swift window's remaining cards, drawn by the page (R82 commit 4): the theme picker by level
// (Appearance), the wallpaper grid (Appearance, behind appearance.experimentalControls), the
// terminal facts (Terminal) and the settings file with its problems (Advanced). Data comes from
// the host lists; writes run host ops or catalog actions, the palette's paths.
import { useState } from "react";
import { useSettingsState, useStore } from "../context";
import { settingsFileName } from "../format";
import { t } from "../strings";
import { ActionRow } from "./ActionRow";

export function ThemeLevels() {
  const store = useStore();
  const { host, domains } = useSettingsState();
  const levels = host?.theme?.levels ?? [];
  const [picked, setPicked] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const [custom, setCustom] = useState<string | null>(null);
  if (!host?.theme || levels.length === 0) return null;
  const level = picked && levels.includes(picked) ? picked : levels[0]!;
  const current = host.theme.current[level] ?? null;
  const text = query.trim();
  const names = text
    ? domains.themes.filter((name) => name.toLowerCase().includes(text.toLowerCase()))
    : domains.themes;
  const onQuery = (value: string) => {
    setQuery(value);
    const typed = value.trim();
    setCustom(null);
    if (typed && !domains.themes.includes(typed)) {
      void store.acceptsTheme(typed).then((accepts) => setCustom(accepts ? typed : null));
    }
  };
  const choice = (title: string, spec: string | null) => (
    <button
      type="button"
      key={spec ?? "\u0000config"}
      className="theme-choice"
      aria-pressed={current === spec}
      onClick={() => void store.setTheme(level, spec)}
    >
      {title}
    </button>
  );
  return (
    <section className="group" data-card="theme">
      <h3 className="group-title">{t("settingsWindow.themePicker")}</h3>
      <div className="theme-picker">
        <fieldset className="segmented" aria-label={t("settingsWindow.themePicker")}>
          {levels.map((id) => (
            <label key={id} className="segment" data-checked={id === level ? "" : undefined}>
              <input
                type="radio"
                name="theme-level"
                value={id}
                aria-label={t(`settingsWindow.themeLevel.${id}`)}
                checked={id === level}
                onChange={() => setPicked(id)}
              />
              {t(`settingsWindow.themeLevel.${id}`)}
            </label>
          ))}
        </fieldset>
        <input
          className="field"
          aria-label={t("settingsWindow.themeSearch")}
          placeholder={t("settingsWindow.themeSearch")}
          value={query}
          onChange={(event) => onQuery(event.target.value)}
        />
        <div className="theme-list" data-theme-list="">
          {choice(t("settingsWindow.themeUseConfig"), null)}
          {custom && custom === text && choice(t("settingsWindow.themeUse", custom), custom)}
          {names.map((name) => choice(name, name))}
        </div>
      </div>
    </section>
  );
}

export function Backdrops() {
  const store = useStore();
  const { host, rows } = useSettingsState();
  const enabled = rows.get("appearance.experimentalControls")?.value === true;
  const backdrops = host?.backdrops ?? [];
  if (!enabled || backdrops.length === 0) return null;
  const current = (rows.get("appearance.background")?.value as string | undefined) ?? "none";
  const tile = (id: string, title: string, attribution: string) => (
    <button
      type="button"
      key={id}
      className="backdrop-tile"
      aria-pressed={current === id}
      aria-label={title}
      onClick={() => void store.set("appearance.background", id)}
    >
      {id === "none" ? (
        <span className="backdrop-thumb backdrop-none" />
      ) : (
        <img className="backdrop-thumb" alt="" src={`backdrop/${encodeURIComponent(id)}`} />
      )}
      <span className="backdrop-title">{title}</span>
      <span className="row-help">{attribution}</span>
    </button>
  );
  return (
    <section className="group" data-card="backdrop">
      <h3 className="group-title">{t("settingsWindow.backdropPicker.title")}</h3>
      <div className="row-help">{t("settingsWindow.backdropPicker.hint")}</div>
      <div className="backdrop-grid">
        {tile("none", t("settingsWindow.backdropPicker.none"), t("settingsWindow.backdropPicker.none"))}
        {backdrops.map((choice) => tile(choice.id, choice.title, choice.attribution))}
      </div>
    </section>
  );
}

export function TerminalInfo() {
  const { host } = useSettingsState();
  if (!host?.terminal) return null;
  return (
    <section className="group" data-card="terminal">
      <div className="row-help">{t("settingsWindow.terminalBody.options")}</div>
      <div className="rows">
        <ActionRow title={t("settingsWindow.ghosttyConfig")} help="">
          <span className="row-help selectable">{host.terminal.ghostty_config}</span>
        </ActionRow>
        <ActionRow title={t("settingsWindow.shellIntegration")} help="">
          <span className="row-help selectable">
            {host.terminal.shell_integration ?? t("settingsWindow.shellIntegrationUnknown")}
          </span>
        </ActionRow>
      </div>
    </section>
  );
}

export function AdvancedInfo() {
  const store = useStore();
  const { host, problems } = useSettingsState();
  return (
    <>
      {host?.settings_file && (
        <section className="group" data-card="advanced">
          <div className="rows">
            <ActionRow title={t("settingsWindow.settingsFile")} help="">
              <span className="row-help selectable">{host.settings_file}</span>
              <button type="button" className="button" onClick={() => store.revealSettingsFile()}>
                {t("settingsWindow.showInFinder")}
              </button>
            </ActionRow>
          </div>
        </section>
      )}
      <section className="group" data-card="problems">
        <h3 className="group-title">{t("settingsWindow.problems", settingsFileName(host))}</h3>
        <div className="rows">
          {problems.length === 0 ? (
            <div className="row">
              <div className="empty">{t("settingsWindow.noProblems")}</div>
            </div>
          ) : (
            problems.map((problem, index) => (
              <div className="row selectable" key={`${problem.path}-${index}`} data-problem="">
                <div className="row-title">{problem.path || settingsFileName(host)}</div>
                <div className="row-help">{problem.message}</div>
              </div>
            ))
          )}
        </div>
      </section>
    </>
  );
}
