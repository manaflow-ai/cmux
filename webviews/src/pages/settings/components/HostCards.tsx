// The Swift window's remaining cards, drawn by the page (R82 commit 4): the wallpaper grid
// (Experimental, behind appearance.experimentalControls), the
// terminal facts (Terminal) and the settings file with its problems (Advanced). Data comes from
// the host lists; writes run host ops or catalog actions, the palette's paths.
import { useState } from "react";
import { useSettingsState, useStore } from "../context";
import { settingsFileName } from "../format";
import { t } from "../strings";
import { ActionRow } from "./ActionRow";
import { ArtBrowser } from "./ArtBrowser";

export function Backdrops() {
  const store = useStore();
  const { host, rows } = useSettingsState();
  const [browsing, setBrowsing] = useState(false);
  const enabled = rows.get("appearance.experimentalControls")?.value === true;
  const backdrops = host?.backdrops ?? [];
  if (!enabled || backdrops.length === 0) return null;
  // Unset is the schema default (a figure drawing), not "none".
  const background = rows.get("appearance.background");
  const current = ((background?.value ?? background?.default) as string | undefined) ?? "none";
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
  // Art arrives grouped by collection (Dark Art, Museum Icons, Calm, Doré), each under its
  // title, then the person's own images ("Your images"); the desktop picture and system
  // wallpapers follow in one untitled group.
  const groups: Array<{ key: string; title: string | null; choices: typeof backdrops }> = [];
  for (const choice of backdrops) {
    const key = choice.collection ?? "";
    const last = groups[groups.length - 1];
    if (last && last.key === key) last.choices.push(choice);
    else groups.push({ key, title: choice.collection_title ?? null, choices: [choice] });
  }
  return (
    <section className="group" data-card="backdrop">
      <h3 className="group-title">{t("settingsWindow.backdropPicker.title")}</h3>
      <div className="backdrop-grid">
        {tile("none", t("settingsWindow.backdropPicker.none"), t("settingsWindow.backdropPicker.none"))}
        <button type="button" className="backdrop-tile" onClick={() => void store.chooseBackdropImage()}>
          <span className="backdrop-thumb backdrop-none backdrop-choose" aria-hidden="true">
            +
          </span>
          <span className="backdrop-title">{t("settingsWindow.backdropPicker.chooseImage")}</span>
          <span className="row-help">{t("settingsWindow.backdropPicker.dropHint")}</span>
        </button>
        <button
          type="button"
          className="backdrop-tile"
          aria-expanded={browsing}
          onClick={() => setBrowsing((open) => !open)}
        >
          <span className="backdrop-thumb backdrop-none backdrop-choose" aria-hidden="true">
            ⌕
          </span>
          <span className="backdrop-title">{t("settingsWindow.artBrowser.open")}</span>
          <span className="row-help">{t("settingsWindow.artBrowser.help")}</span>
        </button>
      </div>
      {browsing && <ArtBrowser onClose={() => setBrowsing(false)} />}
      {groups.map((group) => (
        <div key={group.key || "other"} className="backdrop-group" data-collection={group.key || undefined}>
          {group.title && <h4 className="row-help backdrop-group-title">{group.title}</h4>}
          <div className="backdrop-grid">
            {group.choices.map((choice) => tile(choice.id, choice.title, choice.attribution))}
          </div>
        </div>
      ))}
    </section>
  );
}

export function TerminalInfo() {
  const { host } = useSettingsState();
  if (!host?.terminal) return null;
  return (
    <section className="group" data-card="terminal">
      <div className="rows">
        <ActionRow title={t("settingsWindow.ghosttyConfig")} help="">
          <span className="row-help selectable" title={host.terminal.ghostty_config}>
            {host.terminal.ghostty_config}
          </span>
        </ActionRow>
        <ActionRow title={t("settingsWindow.shellIntegration")} help="">
          <span className="row-help selectable" title={host.terminal.shell_integration ?? undefined}>
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
