// The parts of Spaces & Profiles and Machines that are not schema rows (R82 commit 2): the app's
// live lists (`cmux.settings.host.lists`, updated by `cmux.settings.host.changed`) and the browser
// profile editor, whose every edit runs a `browserProfile.*` catalog action (the palette's path).
import { useState, type ReactNode } from "react";
import { useRowState, useSettingsState, useStore } from "../context";
import { Switch } from "../editors/ToggleEditor";
import type { BrowserProfile, DevicesHostState, HostListRow, HostLists, WireError } from "../ops";
import { rowsByKey } from "../schema";
import { t, text } from "../strings";
import { graphemePrefix } from "../../../ui/initials";

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
  return <>{graphemePrefix(name, 1).toUpperCase() || "?"}</>;
}

function ListRows({
  rows,
  empty,
  marks = false,
  trailing,
  below,
}: {
  rows: HostListRow[];
  empty: string;
  marks?: boolean;
  /** Controls at the row's end (a machine's color). */
  trailing?: (row: HostListRow) => ReactNode;
  /** More of the row, under its title (a Cloud machine's switch). */
  below?: (row: HostListRow) => ReactNode;
}) {
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
        {trailing?.(row)}
      </div>
      {below?.(row)}
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
  const store = useStore();
  const colors = useRowState(MACHINE_COLORS_KEY);
  if (!host) return null;
  const picks = stringMap(colors.value);
  return (
    <>
      <section className="group" data-card="machines">
        <h3 className="group-title">{title}</h3>
        <div className="rows" data-row-key={MACHINE_COLORS_KEY}>
          <ListRows
            rows={host.machines}
            empty={t("settingsWindow.machinesEmpty")}
            marks
            trailing={(row) => (
              <MachineColor
                row={row}
                picks={picks}
                disabled={!colors.connected || !colors.readable || colors.managed !== null}
                write={(next) => void store.set(MACHINE_COLORS_KEY, next)}
              />
            )}
            below={(row) => <MachineVmHost row={row} />}
          />
        </div>
        <div className="host-footer">
          {/* One entry for every new device (add-device-DESIGN.md): Add Device opens the card; it hands
            off to Add Machine or Add Server, and the page passes nothing, so it never approves. */}
          <button
            type="button"
            className="button"
            data-add-device=""
            onClick={() => void store.runAction("device.add")}
          >
            {host.devices?.add_title ?? t("action.device.add")}
          </button>
        </div>
      </section>
      {host.devices && <DevicesSection devices={host.devices} />}
    </>
  );
}

/**
 * Settings > Devices (add-device-DESIGN.md 2.4-2.6): every device that can reach this computer, in
 * words a person reads, each with Remove (a second click confirms), and the recent activity. A
 * paired client machine also has its Full access switch (off unless turned on here), with what it allows.
 */
function DevicesSection({ devices }: { devices: DevicesHostState }) {
  const store = useStore();
  const [confirming, setConfirming] = useState<string | null>(null);
  // Rows with a Full access request in flight: each row holds its own, so a second row's request
  // neither frees the first nor is freed by it.
  const [setting, setSetting] = useState<ReadonlySet<string>>(() => new Set());
  const markSetting = (id: string, pending: boolean) =>
    setSetting((current) => {
      if (current.has(id) === pending) return current;
      const next = new Set(current);
      if (pending) next.add(id);
      else next.delete(id);
      return next;
    });
  return (
    <section className="group" data-card="devices">
      <h3 className="group-title">{devices.title}</h3>
      <div className="rows">
        <div className="row">
          <div className="row-help">{devices.help}</div>
        </div>
        {devices.rows.length === 0 ? (
          <div className="row">
            <div className="empty">{devices.empty}</div>
          </div>
        ) : (
          devices.rows.map((row) => (
            <div className="row" key={row.id} data-device-row={row.id} data-device-state={row.state}>
              <div className="row-main">
                <div className="row-label">
                  <div className="row-title">{row.title}</div>
                  <div className="row-help">{row.subtitle}</div>
                  {row.detail && <div className="row-help">{row.detail}</div>}
                  {confirming === row.id && <div className="row-help">{devices.remove_help}</div>}
                </div>
                {row.removable && (
                  <button
                    type="button"
                    className="button"
                    data-remove-device={row.id}
                    onClick={() => {
                      if (confirming !== row.id) return setConfirming(row.id);
                      setConfirming(null);
                      void store.removeDevice(row.id);
                    }}
                    onBlur={() => setConfirming((current) => (current === row.id ? null : current))}
                  >
                    {confirming === row.id ? devices.remove_confirm_title : devices.remove_title}
                  </button>
                )}
              </div>
              {typeof row.full_access === "boolean" && (
                <div className="row-main device-full-access" data-device-full-access={row.id}>
                  <div className="row-label">
                    <div className="row-title" id={`device-full-access-${row.id}`}>
                      {devices.full_access_title}
                    </div>
                    {row.full_access_help && <div className="row-help">{row.full_access_help}</div>}
                  </div>
                  <div className="row-control">
                    <Switch
                      checked={row.full_access}
                      disabled={setting.has(row.id)}
                      labelId={`device-full-access-${row.id}`}
                      onToggle={(on) => {
                        markSetting(row.id, true);
                        void store
                          .setDeviceFullAccess(row.id, on)
                          .finally(() => markSetting(row.id, false))
                          .catch(() => undefined);
                      }}
                    />
                  </div>
                </div>
              )}
            </div>
          ))
        )}
        {devices.error && (
          <div className="row">
            <div className="row-help" role="alert">
              {devices.error}
            </div>
          </div>
        )}
      </div>
      {devices.activity.length > 0 && (
        <>
          <h3 className="group-title">{devices.activity_title}</h3>
          <div className="rows" data-device-activity="">
            {devices.activity.map((entry, index) => (
              <div className="row" key={`${entry.time}-${index}`}>
                <div className="row-label">
                  <div className="row-title">
                    {entry.what} {entry.subject}
                  </div>
                  <div className="row-help">{new Date(entry.time).toLocaleString()}</div>
                </div>
              </div>
            ))}
          </div>
        </>
      )}
    </section>
  );
}

/**
 * A Cloud machine's "Dedicated agent machine" switch (acpmux vmHost): on (the default), the machine
 * takes the VM boundary when this app's own link asks for it, so chats from this Mac run without the
 * sandbox there; off, they keep it. The host sends it only while the Cloud API says the signed-in
 * caller owns the machine. Turning it on takes the person's click.
 */
function MachineVmHost({ row }: { row: HostListRow }) {
  const store = useStore();
  const [setting, setSetting] = useState(false);
  const vm = row.vm_host;
  if (!vm) return null;
  const label = `machine-vm-host-${row.id}`;
  return (
    <div className="row-main device-full-access" data-machine-vm-host={row.id}>
      <div className="row-label">
        <div className="row-title" id={label}>
          {t("settingsWindow.vmHost")}
        </div>
        <div className="row-help">{t("settingsWindow.vmHostHelp")}</div>
        {vm.error && (
          <div className="row-help" role="alert">
            {vm.error}
          </div>
        )}
      </div>
      <div className="row-control">
        <Switch
          checked={vm.on}
          disabled={setting || vm.busy}
          labelId={label}
          onToggle={(on) => {
            setSetting(true);
            void store.setMachineVmHost(row.id, on).finally(() => setSetting(false));
          }}
        />
      </div>
    </div>
  );
}

/** `appearance.machineColors`: a machine's color, keyed by its color key. The card draws it, not a map row. */
export const MACHINE_COLORS_KEY = "appearance.machineColors";

function stringMap(value: unknown): Record<string, string> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return {};
  return Object.fromEntries(
    Object.entries(value).filter((entry): entry is [string, string] => typeof entry[1] === "string"),
  );
}

/**
 * A machine's color on its row: the well shows the color its marks draw in (the pick, else the
 * automatic one the host sends) and picks another; Automatic takes the pick back. Each change writes
 * the whole map, keeping every other machine's pick. The well commits on the native `change` event
 * (the panel closing), not on every move.
 */
function MachineColor({
  row,
  picks,
  disabled,
  write,
}: {
  row: HostListRow;
  picks: Record<string, string>;
  disabled: boolean;
  write: (next: Record<string, string>) => void;
}) {
  const key = row.color_key;
  if (!key || !row.color) return null;
  // cmux.json may spell the machine another way ("Big-Red "); the app reads the first in key order.
  const own = Object.keys(picks).filter((name) => name.trim().toLowerCase() === key);
  own.sort();
  const rest = Object.fromEntries(Object.entries(picks).filter(([name]) => !own.includes(name)));
  const pick = own.length > 0 ? picks[own[0]!] : undefined;
  // An accent pick ("cyan") has no hex here; the host's color is that accent in the theme.
  const shown = (pick?.startsWith("#") ? pick : row.color).toLowerCase();
  const label = `${text(rowsByKey.get(MACHINE_COLORS_KEY)?.title)} ${row.title}`;
  const wellRef = (well: HTMLInputElement | null) => {
    if (!well) return;
    const onChange = () => write({ ...rest, [key]: well.value.toLowerCase() });
    well.addEventListener("change", onChange);
    return () => well.removeEventListener("change", onChange);
  };
  return (
    <span className="host-actions" data-machine-color={key}>
      {/* Uncontrolled, so the open panel keeps its color; a new color remounts it. */}
      <input
        key={shown}
        ref={wellRef}
        type="color"
        className="swatch"
        aria-label={label}
        defaultValue={shown}
        disabled={disabled}
      />
      {pick !== undefined && (
        <button
          type="button"
          className="button"
          data-machine-color-reset=""
          disabled={disabled}
          onClick={() => write(rest)}
        >
          {t("settingsPage.automatic")}
        </button>
      )}
    </span>
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
  const [error, setError] = useState<WireError | null>(null);
  const title = t("action.browserProfile.clearBrowsingData").replace(/…$/, "");
  // "Cleared" once the app took the run; a refused run shows the owner's error.
  const clear = async () => {
    setCleared(false);
    setError(null);
    const reply = await store.runAction("browserProfile.clearBrowsingData", { range, ...kinds }, target);
    if (!reply.ok) {
      setError(reply.error);
      return;
    }
    if (typeof reply.value === "object" && reply.value !== null && "ran" in reply.value && reply.value.ran === false) {
      setError({ code: "cmux.app.action_refused", message: "action refused" });
      return;
    }
    setCleared(true);
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
      {error && (
        <output className="row-error clear-browsing-data-error" data-clear-error="" role="alert">
          {t(
            error.code === "cmux.browser.clear_refused"
              ? "settingsWindow.browsingDataClearRefused"
              : "settingsWindow.browsingDataClearFailed",
          )}
        </output>
      )}
    </div>
  );
}
