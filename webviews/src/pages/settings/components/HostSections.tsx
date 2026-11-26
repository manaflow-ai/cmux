// The parts of Spaces & Profiles and Machines that are not schema rows (R82 commit 2): the app's
// live lists (`cmux.settings.host.lists`, updated by `cmux.settings.host.changed`) and the browser
// profile editor, whose every edit runs a `browserProfile.*` catalog action (the palette's path).
import { Input } from "../../../ui/Input";
import { Button } from "../../../ui/Button";
import { memo, useLayoutEffect, useMemo, useRef, useState } from "react";
import { useStableHandlers } from "../../../agent-session/acpmux/stableHandlers";
import { useKeptItems } from "../keptItems";
import { useRowState, useSettingsState, useStore } from "../context";
import { Switch } from "../editors/ToggleEditor";
import type {
  BrowserProfile,
  DeviceRow as DeviceHostRow,
  DevicesHostState,
  HostListRow,
  HostLists,
  WireError,
} from "../ops";
import { rowsByKey } from "../schema";
import { t, text } from "../strings";
import { graphemePrefix } from "../../../ui/initials";
import { LOAD_FADE_CLASS, useLoadFade } from "../../../agent-session/shared/loadFade";
import { MACHINE_COLORS_KEY, SPACE_ROWS, useSeveralSpaces } from "../cardRows";

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

/** A machine row's color, from the whole map of picks: what its well shows and offers. */
type MachinePick = {
  /** The pick for this machine's color key, if any ("Big-Red " and "big-red" are the same key). */
  pick: string | undefined;
  disabled: boolean;
  /** Writes this machine's pick (null: Automatic), keeping every other machine's. */
  onPick: (key: string, color: string | null) => void;
};

function ListRows({
  rows,
  empty,
  marks = false,
  machines,
}: {
  rows: HostListRow[];
  empty: string;
  marks?: boolean;
  /** Machines (Machines card): each row has its color and, for a Cloud machine, its switch. */
  machines?: { picks: Record<string, string>; disabled: boolean; onPick: MachinePick["onPick"] };
}) {
  // The host sends its lists whole on every change: a row that did not change keeps its object.
  const kept = useKeptItems(rows, (row) => row.id);
  if (kept.length === 0) {
    return (
      <div className="row">
        <div className="empty">{empty}</div>
      </div>
    );
  }
  return kept.map((row) => (
    <HostRow
      key={row.id}
      row={row}
      marks={marks}
      machine={machines !== undefined}
      pick={machines && row.color_key ? pickOf(machines.picks, row.color_key) : undefined}
      disabled={machines?.disabled ?? false}
      onPick={machines?.onPick}
    />
  ));
}

/**
 * One space or machine, a memo row: its own host row (a host change that left it alone keeps the
 * object), its own color pick and one stable `onPick`, so a host change or another machine's pick
 * draws only the rows it changed.
 */
const HostRow = memo(function HostRow({
  row,
  marks,
  machine,
  pick,
  disabled,
  onPick,
}: {
  row: HostListRow;
  marks: boolean;
  machine: boolean;
  pick: string | undefined;
  disabled: boolean;
  onPick?: MachinePick["onPick"];
}) {
  return (
    <div className="row" data-host-row={row.id}>
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
        {machine && onPick && <MachineColor row={row} pick={pick} disabled={disabled} onPick={onPick} />}
      </div>
      {machine && <MachineVmHost row={row} />}
      {machine && <MachineAutoCloud row={row} />}
    </div>
  );
});

/** The pick for a color key: cmux.json may spell the machine another way ("Big-Red "); the app reads
 * the first in key order. */
function pickOf(picks: Record<string, string>, key: string): string | undefined {
  const own = Object.keys(picks)
    .filter((name) => name.trim().toLowerCase() === key)
    .sort();
  return own.length > 0 ? picks[own[0]!] : undefined;
}

/**
 * Spaces (Sidebar): the active window's spaces, from the second space on. With one space (or a host
 * without spaces) no part of cmux names spaces (Hide Spaces, 2026-11-20), so the card is not drawn.
 */
export function SpacesSection() {
  const { host } = useSettingsState();
  const rooms = host?.rooms ?? [];
  // The card arrives with the host's lists: after a blank first paint it fades in (shared/loadFade.ts).
  const fade = useLoadFade(rooms.length > 1);
  if (rooms.length < 2) return null;
  return (
    <section className={fade ? `group ${LOAD_FADE_CLASS}` : "group"} data-card="rooms">
      <h3 className="group-title">{t("settingsPage.group.spaces")}</h3>
      <div className="rows">
        <ListRows rows={rooms} empty={t("settingsWindow.roomsEmpty")} marks />
      </div>
    </section>
  );
}

/** Browser profiles (Browser). */
export function BrowserProfiles() {
  const { host } = useSettingsState();
  return host ? <BrowserProfilesSection host={host} /> : null;
}

/** `reveal`: the route opens Settings at Machines (`#/settings/machines`). The card moves to the top
 * in the commit that draws it (or that turns `reveal` on), before the frame paints, so the page
 * never shows the top of Accounts first. */
export function MachinesSection({ title, reveal = false }: { title: string; reveal?: boolean }) {
  const { host } = useSettingsState();
  const store = useStore();
  const colors = useRowState(MACHINE_COLORS_KEY);
  const picks = useMemo(() => stringMap(colors.value), [colors.value]);
  // Each change writes the whole map, keeping every other machine's pick (every spelling of this one goes).
  const { onPick } = useStableHandlers({
    onPick: (key: string, color: string | null) => {
      const rest = Object.fromEntries(Object.entries(picks).filter(([name]) => name.trim().toLowerCase() !== key));
      void store.set(MACHINE_COLORS_KEY, color === null ? rest : { ...rest, [key]: color });
    },
  });
  const card = useRef<HTMLElement>(null);
  const drawn = host !== null;
  useLayoutEffect(() => {
    if (drawn && reveal) card.current?.scrollIntoView?.({ block: "start" });
  }, [drawn, reveal]);
  // The card arrives with the host's lists: after a blank first paint it fades in (shared/loadFade.ts).
  const fade = useLoadFade(Boolean(host));
  if (!host) return null;
  return (
    <>
      <section className={fade ? `group ${LOAD_FADE_CLASS}` : "group"} data-card="machines" ref={card}>
        <h3 className="group-title">{title}</h3>
        <div className="rows" data-row-key={MACHINE_COLORS_KEY}>
          <ListRows
            rows={host.machines}
            empty={t("settingsWindow.machinesEmpty")}
            marks
            machines={{ picks, disabled: !colors.connected || !colors.readable || colors.managed !== null, onPick }}
          />
        </div>
        <div className="host-footer">
          {/* One entry for every new device (add-device-DESIGN.md): Add Device opens the card; it hands
            off to Add Machine or Add Server, and the page passes nothing, so it never approves. */}
          <Button
            type="button"
            className="button"
            data-add-device=""
            onClick={() => void store.runAction("device.add")}
          >
            {host.devices?.add_title ?? t("action.device.add")}
          </Button>
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
  const deviceRows = useKeptItems(devices.rows, (row) => row.id);
  const { onRemove, onRemoveBlur, onFullAccess } = useStableHandlers({
    onRemove: (id: string) => {
      if (confirming !== id) return setConfirming(id);
      setConfirming(null);
      void store.removeDevice(id);
    },
    onRemoveBlur: (id: string) => setConfirming((current) => (current === id ? null : current)),
    onFullAccess: (id: string, on: boolean) => {
      markSetting(id, true);
      void store
        .setDeviceFullAccess(id, on)
        .finally(() => markSetting(id, false))
        .catch(() => undefined);
    },
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
          deviceRows.map((row) => (
            <DeviceRow
              key={row.id}
              row={row}
              removeHelp={devices.remove_help}
              removeTitle={devices.remove_title}
              removeConfirmTitle={devices.remove_confirm_title}
              fullAccessTitle={devices.full_access_title}
              confirming={confirming === row.id}
              setting={setting.has(row.id)}
              onRemove={onRemove}
              onRemoveBlur={onRemoveBlur}
              onFullAccess={onFullAccess}
            />
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
            {activityKeys(devices.activity).map((key, index) => {
              const entry = devices.activity[index]!;
              return <ActivityRow key={key} time={entry.time} what={entry.what} subject={entry.subject} />;
            })}
          </div>
        </>
      )}
    </section>
  );
}

/**
 * One device, a memo row: its own host row, the card's words for it,
 * whether its Remove asks again and whether its Full access request is out, and stable handlers,
 * so another row's Remove or Full access, or a host change that left it alone, does not draw it.
 */
const DeviceRow = memo(function DeviceRow({
  row,
  removeHelp,
  removeTitle,
  removeConfirmTitle,
  fullAccessTitle,
  confirming,
  setting,
  onRemove,
  onRemoveBlur,
  onFullAccess,
}: {
  row: DeviceHostRow;
  removeHelp: string;
  removeTitle: string;
  removeConfirmTitle: string;
  fullAccessTitle: string;
  confirming: boolean;
  setting: boolean;
  onRemove: (id: string) => void;
  onRemoveBlur: (id: string) => void;
  onFullAccess: (id: string, on: boolean) => void;
}) {
  return (
    <div className="row" data-device-row={row.id} data-device-state={row.state}>
      <div className="row-main">
        <div className="row-label">
          <div className="row-title">{row.title}</div>
          <div className="row-help">{row.subtitle}</div>
          {row.detail && <div className="row-help">{row.detail}</div>}
          {confirming && <div className="row-help">{removeHelp}</div>}
        </div>
        {row.removable && (
          <Button
            type="button"
            className="button"
            data-remove-device={row.id}
            onClick={() => onRemove(row.id)}
            onBlur={() => onRemoveBlur(row.id)}
          >
            {confirming ? removeConfirmTitle : removeTitle}
          </Button>
        )}
      </div>
      {typeof row.full_access === "boolean" && (
        <div className="row-main device-full-access" data-device-full-access={row.id}>
          <div className="row-label">
            <div className="row-title" id={`device-full-access-${row.id}`}>
              {fullAccessTitle}
            </div>
            {row.full_access_help && <div className="row-help">{row.full_access_help}</div>}
          </div>
          <div className="row-control">
            <Switch
              checked={row.full_access}
              disabled={setting}
              labelId={`device-full-access-${row.id}`}
              onToggle={(on) => onFullAccess(row.id, on)}
            />
          </div>
        </div>
      )}
    </div>
  );
});

/**
 * Each activity line's key: what it says, with a count for a repeat. The host sends the last 8 lines
 * (DeviceDirectory's `device audit --limit 8`), so a new line drops the oldest and shifts the
 * others' indexes; a key from the content keeps the lines already drawn mounted.
 */
function activityKeys(activity: DevicesHostState["activity"]): string[] {
  const seen = new Map<string, number>();
  return activity.map((entry) => {
    const base = `${entry.time}\u0000${entry.what}\u0000${entry.subject}`;
    const count = seen.get(base) ?? 0;
    seen.set(base, count + 1);
    return count === 0 ? base : `${base}\u0000${count}`;
  });
}

/** One activity line. Its props are strings, so a host change or a device row's gesture skips it. */
const ActivityRow = memo(function ActivityRow({
  time,
  what,
  subject,
}: {
  time: string;
  what: string;
  subject: string;
}) {
  return (
    <div className="row">
      <div className="row-label">
        <div className="row-title">
          {what} {subject}
        </div>
        <div className="row-help">{new Date(time).toLocaleString()}</div>
      </div>
    </div>
  );
});

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

/** The capability badges AutoCloud matches work against, in the order a person scans them, and
 * each one's label. */
const AUTOCLOUD_CAPS: ReadonlyArray<readonly [string, string]> = [
  ["macos", "settingsWindow.autoCloudCap.macos"],
  ["xcode", "settingsWindow.autoCloudCap.xcode"],
  ["ios-simulator", "settingsWindow.autoCloudCap.ios-simulator"],
  ["gpu-metal", "settingsWindow.autoCloudCap.gpu-metal"],
  ["linux", "settingsWindow.autoCloudCap.linux"],
  ["gpu-nvidia", "settingsWindow.autoCloudCap.gpu-nvidia"],
];

/**
 * A Remote machine's AutoCloud enrollment (acpmux `_acpmux/autocloud_enroll` on that machine, its
 * `health.autoCloud`): on, AutoCloud may place work there after this Mac and before the cloud
 * pool, only while its owner is away; the owner's own use always wins. Only the owner's own client
 * turns it on, so this row reads it: the policy, whether it takes work now, and what it can run.
 */
function MachineAutoCloud({ row }: { row: HostListRow }) {
  const ac = row.autocloud;
  if (!ac) return null;
  const policy = ac.policy;
  const teams = policy?.teams ?? [];
  const parts = [teams.length === 0 ? t("settingsWindow.autoCloudOwnerOnly") : teams.join(", ")];
  if (policy?.agents.length) parts.push(policy.agents.join(", "));
  if (policy?.hours)
    parts.push(t("settingsWindow.autoCloudHours", hourText(policy.hours.from), hourText(policy.hours.to)));
  const status = !ac.on
    ? t("settingsWindow.autoCloudOff")
    : ac.accepting
      ? t("settingsWindow.autoCloudAccepting")
      : ac.owner_idle === false
        ? t("settingsWindow.autoCloudOwnerActive")
        : t("settingsWindow.autoCloudPaused");
  const caps = AUTOCLOUD_CAPS.filter(([cap]) => ac.caps?.includes(cap));
  return (
    <div className="row-main device-full-access" data-machine-autocloud={row.id} data-autocloud-on={ac.on}>
      <div className="row-label">
        <div className="row-title">{t("settingsWindow.autoCloudEnroll")}</div>
        <div className="row-help" data-autocloud-status>
          {status}
        </div>
        {ac.on && (
          <div className="row-help" data-autocloud-policy>
            {parts.join(" · ")}
          </div>
        )}
        {ac.on && caps.length > 0 && (
          <div className="autocloud-caps" data-autocloud-caps>
            {caps.map(([cap, key]) => (
              <span key={cap} className="autocloud-cap">
                {t(key)}
              </span>
            ))}
          </div>
        )}
        <div className="row-help">{t("settingsWindow.autoCloudEnrollHelp")}</div>
        {ac.error && (
          <div className="row-help" role="alert">
            {ac.error}
          </div>
        )}
      </div>
    </div>
  );
}

/** "9:00" for 9, local hours as acpmux keeps them. */
function hourText(h: number): string {
  return `${Math.floor(h)}:00`;
}

export { MACHINE_COLORS_KEY, SPACE_ROWS, useSeveralSpaces };

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
  pick,
  disabled,
  onPick,
}: {
  row: HostListRow;
  pick: string | undefined;
  disabled: boolean;
  onPick: MachinePick["onPick"];
}) {
  const key = row.color_key;
  if (!key || !row.color) return null;
  // An accent pick ("cyan") has no hex here; the host's color is that accent in the theme.
  const shown = (pick?.startsWith("#") ? pick : row.color).toLowerCase();
  const label = `${text(rowsByKey.get(MACHINE_COLORS_KEY)?.title)} ${row.title}`;
  const wellRef = (well: HTMLInputElement | null) => {
    if (!well) return;
    const onChange = () => onPick(key, well.value.toLowerCase());
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
        <Button
          type="button"
          className="button"
          data-machine-color-reset=""
          disabled={disabled}
          onClick={() => onPick(key, null)}
        >
          {t("settingsPage.automatic")}
        </Button>
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
        <Button
          type="button"
          className="button"
          data-new-profile=""
          onClick={() => void store.runAction("browserProfile.new")}
        >
          {t("settingsWindow.newBrowserProfile")}
        </Button>
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
            <Input
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
            <Input
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
            <Button type="button" className="button" onClick={() => run("browserProfile.manageExtensions")}>
              {t("action.browserProfile.manageExtensions").replace(/…$/, "")}
            </Button>
            {!profile.is_default && (
              <Button
                danger
                type="button"
                className="button danger"
                data-delete-profile=""
                onClick={() => run("browserProfile.delete")}
              >
                {t("settingsWindow.deleteProfile")}
              </Button>
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
        <Button
          danger
          type="button"
          className="button danger"
          data-clear=""
          disabled={!CLEAR_KINDS.some((kind) => kinds[kind])}
          onClick={() => void clear()}
        >
          {title}
        </Button>
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
