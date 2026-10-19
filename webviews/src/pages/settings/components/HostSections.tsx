// The parts of Spaces & Profiles and Machines that are not schema rows (R82 commit 2): the app's
// live lists (`cmux.settings.host.lists`, updated by `cmux.settings.host.changed`) and the browser
// profile editor, whose every edit runs a `browserProfile.*` catalog action (the palette's path).
import { useState } from "react";
import { useSettingsState, useStore } from "../context";
import type { BrowserProfile, HostListRow, HostLists } from "../ops";
import { t } from "../strings";

const ASSET_ICON = /^(image|svg):sha256-[0-9a-f]{64}$/;

/**
 * A mark's content: a stored image or SVG as the host's PNG of it (`icon/<ref>`, cx-qno.2.3), an
 * emoji as itself, else the name's initial (an SF Symbol name is not drawable here).
 */
function IconMark({ icon, name }: { icon: string | null | undefined; name: string }) {
  if (icon && ASSET_ICON.test(icon)) {
    return <img className="host-avatar-image" alt="" src={`icon/${encodeURIComponent(icon)}`} />;
  }
  if (icon && !/^[a-z0-9.]+$/.test(icon)) return <>{icon}</>;
  return <>{name.slice(0, 1).toUpperCase() || "?"}</>;
}

function ListRows({ rows, empty, marks = false }: { rows: HostListRow[]; empty: string; marks?: boolean }) {
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
        {marks && (
          <span className="host-avatar" aria-hidden="true">
            <IconMark icon={row.icon} name={row.title} />
          </span>
        )}
        <div className="row-label">
          <div className="row-title">{row.title}</div>
          {row.subtitle && <div className="row-help">{row.subtitle}</div>}
        </div>
        {row.active && <span className="host-active" aria-hidden="true" />}
      </div>
    </div>
  ));
}

/** Spaces (General): the active window's spaces, or why the host has none. */
export function SpacesSection() {
  const { host } = useSettingsState();
  if (!host) return null;
  return (
    <section className="group" data-card="rooms">
      <h3 className="group-title">{t("settingsPage.group.spaces")}</h3>
      <div className="rows">
        {host.rooms ? (
          <ListRows rows={host.rooms} empty={t("settingsWindow.roomsEmpty")} marks />
        ) : (
          <div className="row">
            <div className="empty">{t("settingsWindow.roomsUnavailable")}</div>
          </div>
        )}
      </div>
    </section>
  );
}

/** Browser profiles (Browser). */
export function BrowserProfiles() {
  const { host } = useSettingsState();
  return host ? <BrowserProfilesSection host={host} /> : null;
}

export function MachinesSection({ title }: { title: string }) {
  const { host } = useSettingsState();
  if (!host) return null;
  return (
    <section className="group" data-card="machines">
      <h3 className="group-title">{title}</h3>
      <div className="rows">
        <ListRows rows={host.machines} empty={t("settingsWindow.machinesEmpty")} marks />
      </div>
    </section>
  );
}

/** Phone Access (Accounts): the phones allowed to use this Mac, each with Remove. */
export function PhonesSection() {
  const { host } = useSettingsState();
  const store = useStore();
  if (!host) return null;
  const phones = host.phones ?? [];
  return (
    <section className="group" data-card="phones">
      <h3 className="group-title">{t("settingsWindow.phonesTitle")}</h3>
      <div className="rows">
        {phones.length === 0 ? (
          <div className="row">
            <div className="empty">{t("settingsWindow.phonesEmpty")}</div>
          </div>
        ) : (
          phones.map((phone) => (
            <div className="row" key={phone.id} data-host-row={phone.id}>
              <div className="row-main">
                <div className="row-label">
                  <div className="row-title">{phone.title}</div>
                  {phone.subtitle && <div className="row-help">{phone.subtitle}</div>}
                </div>
                <button
                  type="button"
                  className="button danger"
                  data-remove-phone={phone.id}
                  onClick={() => void store.removePhone(phone.id)}
                >
                  {t("settingsWindow.removePhone")}
                </button>
              </div>
            </div>
          ))
        )}
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
      </div>
    </section>
  );
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
  // The color fills the mark's disc; a stored image draws with none.
  const asset = profile.icon != null && ASSET_ICON.test(profile.icon);
  const fill = asset ? undefined : colors.find((color) => color.name === profile.color)?.fill;
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
          <IconMark icon={profile.icon} name={profile.name} />
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
              aria-label={t("settingsWindow.profileName")}
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
              aria-label={t("settingsWindow.profileIcon")}
              value={icon}
              onChange={(event) => setDraft({ for: current, name, icon: event.target.value })}
              onKeyDown={(event) => {
                if (event.key !== "Enter") return;
                if (icon.trim()) run("browserProfile.setIcon", { icon: icon.trim() });
                else run("browserProfile.clearIcon");
              }}
            />
          </label>
          <ClearBrowsingData target={target} />
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

const CLEAR_RANGES = ["hour", "today", "week", "month", "all"] as const;
const CLEAR_KINDS = ["history", "cookies", "cache"] as const;

/**
 * A profile's Clear Browsing Data (cx-d0d.23, Chrome's): a time range (the last hour first) and
 * the kinds to clear, inline in the profile's row, never a sheet. Runs the profile's
 * `browserProfile.clearBrowsingData`, the action the palette, the CLI and MCP run.
 */
function ClearBrowsingData({ target }: { target: string }) {
  const store = useStore();
  const [range, setRange] = useState<(typeof CLEAR_RANGES)[number]>("hour");
  const [kinds, setKinds] = useState<Record<(typeof CLEAR_KINDS)[number], boolean>>({
    history: true,
    cookies: true,
    cache: true,
  });
  const [cleared, setCleared] = useState(false);
  const title = t("action.browserProfile.clearBrowsingData").replace(/…$/, "");
  // "Cleared" once the app took the run; a refused run shows nothing.
  const clear = async () => {
    setCleared(false);
    try {
      await store.runAction("browserProfile.clearBrowsingData", { range, ...kinds }, target);
      setCleared(true);
    } catch {
      setCleared(false);
    }
  };
  return (
    <div className="host-field" data-clear-browsing-data="">
      <span className="row-help">{title}</span>
      <select
        className="field"
        aria-label={title}
        value={range}
        onChange={(event) => {
          setCleared(false);
          setRange(event.target.value as (typeof CLEAR_RANGES)[number]);
        }}
      >
        {CLEAR_RANGES.map((value) => (
          <option key={value} value={value}>
            {t(`argument.history.range.${value}`)}
          </option>
        ))}
      </select>
      {CLEAR_KINDS.map((kind) => (
        <label key={kind} className="row-help">
          <input
            type="checkbox"
            name={kind}
            aria-label={t(`argument.browsingData.${kind}`)}
            checked={kinds[kind]}
            onChange={(event) => {
              setCleared(false);
              setKinds({ ...kinds, [kind]: event.currentTarget.checked });
            }}
          />{" "}
          {t(`argument.browsingData.${kind}`)}
        </label>
      ))}
      <span className="host-actions">
        <button
          type="button"
          className="button danger"
          data-clear=""
          disabled={!CLEAR_KINDS.some((kind) => kinds[kind])}
          onClick={() => void clear()}
        >
          {title}
        </button>
        {cleared && (
          <output className="row-help" data-cleared="">
            {t("settingsWindow.browsingDataCleared")}
          </output>
        )}
      </span>
    </div>
  );
}
