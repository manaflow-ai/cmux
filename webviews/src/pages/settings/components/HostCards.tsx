// The Swift window's remaining cards, drawn by the page (R82 commit 4): the wallpaper grid
// (Experimental, behind appearance.experimentalControls), the
// terminal facts (Terminal) and the settings file with its problems (Advanced). Data comes from
// the host lists; writes run host ops or catalog actions, the palette's paths.
import { useSettingsState, useStore } from "../context";
import { settingsFileName } from "../format";
import { t } from "../strings";
import { ActionRow } from "./ActionRow";

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
