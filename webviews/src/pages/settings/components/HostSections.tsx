// The parts of Spaces & Profiles and Machines that are not schema rows (R82 commit 2): the app's
// live lists (`cmux.settings.host.lists`, updated by `cmux.settings.host.changed`) and the browser
// profile editor, whose every edit runs a `browserProfile.*` catalog action (the palette's path).
import { useState } from "react";
import { useSettingsState, useStore } from "../context";
import type { BrowserProfile, HostListRow, HostLists } from "../ops";
import { t } from "../strings";

function ListRows({ rows, empty }: { rows: HostListRow[]; empty: string }) {
  if (rows.length === 0) {
    return (
      <div className="row">
        <div className="empty">{empty}</div>
      </div>
    );
  }
  return rows.map((row) => (
    <div className="row" key={row.id} data-host-row={row.id}>
      <div className="row-main">
        <div className="row-label">
          <div className="row-title">{row.title}</div>
          {row.subtitle && <div className="row-help">{row.subtitle}</div>}
        </div>
        {row.active && <span className="host-active" aria-hidden="true" />}
      </div>
    </div>
  ));
}

export function RoomsSection() {
  const { host } = useSettingsState();
  if (!host) return null;
  return (
    <>
      <section className="group" data-card="rooms">
        <div className="rows">
          {host.rooms ? (
            <ListRows rows={host.rooms} empty={t("settingsWindow.roomsEmpty")} />
          ) : (
            <div className="row">
              <div className="empty">{t("settingsWindow.roomsUnavailable")}</div>
            </div>
          )}
        </div>
      </section>
      <BrowserProfilesSection host={host} />
    </>
  );
}

export function MachinesSection() {
  const { host } = useSettingsState();
  if (!host) return null;
  return (
    <section className="group" data-card="machines">
      <div className="rows">
        <ListRows rows={host.machines} empty={t("settingsWindow.machinesEmpty")} />
      </div>
    </section>
  );
}

function BrowserProfilesSection({ host }: { host: HostLists }) {
  const store = useStore();
  const [expanded, setExpanded] = useState<string | null>(null);
  return (
    <section className="group" data-card="browserProfiles">
      <h3 className="group-title">{t("settingsWindow.browserProfiles")}</h3>
      <div className="rows">
        {host.browser_profiles.map((profile) => (
          <ProfileRow
            key={profile.id}
            profile={profile}
            colors={host.profile_colors}
            expanded={expanded === profile.id}
            onToggle={() => setExpanded(expanded === profile.id ? null : profile.id)}
          />
        ))}
      </div>
      <div className="host-footer">
        <button
          type="button"
          className="button"
          data-new-profile=""
          onClick={() => void store.runAction("browserProfile.new")}
        >
          {t("settingsWindow.newBrowserProfile")}
        </button>
        <span className="row-help">{t("settingsWindow.browserProfilesHint")}</span>
      </div>
    </section>
  );
}

function avatarText(profile: BrowserProfile): string {
  // An SF Symbol name is not drawable here; an emoji is.
  if (profile.icon && !/^[a-z0-9.]+$/.test(profile.icon)) return profile.icon;
  return profile.name.slice(0, 1).toUpperCase() || "?";
}

function ProfileRow({
  profile,
  colors,
  expanded,
  onToggle,
}: {
  profile: BrowserProfile;
  colors: HostLists["profile_colors"];
  expanded: boolean;
  onToggle: () => void;
}) {
  const store = useStore();
  const target = `browser-profile:${profile.id}`;
  const fill = colors.find((color) => color.name === profile.color)?.fill;
  // Drafts reset to the profile's values whenever it changes (keyed by the profile's state).
  const [draft, setDraft] = useState({
    for: `${profile.name}\u0000${profile.icon ?? ""}`,
    name: profile.name,
    icon: profile.icon ?? "",
  });
  const current = `${profile.name}\u0000${profile.icon ?? ""}`;
  const name = draft.for === current ? draft.name : profile.name;
  const icon = draft.for === current ? draft.icon : (profile.icon ?? "");
  const run = (action: Parameters<typeof store.runAction>[0], args: Record<string, unknown> = {}) =>
    void store.runAction(action, args, target);
  return (
    <div className="row" data-profile={profile.id}>
      <button type="button" className="row-main host-toggle" aria-expanded={expanded} onClick={onToggle}>
        <span className="host-avatar" style={fill ? { background: fill } : undefined}>
          {avatarText(profile)}
        </span>
        <span className="row-label">
          <span className="row-title">{profile.name}</span>
          {profile.source && <span className="row-help"> {profile.source}</span>}
        </span>
      </button>
      {expanded && (
        <div className="host-form">
          <label className="host-field">
            <span className="row-help">{t("settingsWindow.profileName")}</span>
            <input
              className="field"
              value={name}
              onChange={(event) => setDraft({ for: current, name: event.target.value, icon })}
              onKeyDown={(event) => {
                if (event.key === "Enter" && name.trim()) run("browserProfile.rename", { name: name.trim() });
              }}
            />
          </label>
          <div className="host-field">
            <span className="row-help">{t("settingsWindow.profileColor")}</span>
            <span className="host-swatches">
              {colors.map((color) => (
                <button
                  type="button"
                  key={color.name}
                  className="host-swatch"
                  aria-label={color.name}
                  aria-pressed={profile.color === color.name}
                  style={{ background: color.swatch }}
                  onClick={() => run("browserProfile.setColor", { color: color.name })}
                />
              ))}
              <button
                type="button"
                className="host-swatch host-swatch-clear"
                aria-label={t("settingsWindow.reset")}
                onClick={() => run("browserProfile.clearColor")}
              />
            </span>
          </div>
          <label className="host-field">
            <span className="row-help">{t("settingsWindow.profileIcon")}</span>
            <input
              className="field"
              value={icon}
              onChange={(event) => setDraft({ for: current, name, icon: event.target.value })}
              onKeyDown={(event) => {
                if (event.key !== "Enter") return;
                if (icon.trim()) run("browserProfile.setIcon", { icon: icon.trim() });
                else run("browserProfile.clearIcon");
              }}
            />
          </label>
          <div className="host-actions">
            <button type="button" className="button" onClick={() => run("browserProfile.manageExtensions")}>
              {t("action.browserProfile.manageExtensions").replace(/…$/, "")}
            </button>
            {!profile.is_default && (
              <button
                type="button"
                className="button danger"
                data-delete-profile=""
                onClick={() => run("browserProfile.delete")}
              >
                {t("settingsWindow.deleteProfile")}
              </button>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
