// Settings > Devices: this Mac and the person's other devices on the device hub (docs/device-hub),
// who may use Mac Screen on this Mac, the relays this Mac knows and the access history. The host
// sends the screen as data with every text localized (`cmux.settings.devices.state`, live through
// `cmux.settings.devices.changed`) and runs each gesture (`cmux.settings.devices.run`); the page
// only draws and forwards. A relay secret typed in the editor lives in that form's state until it
// is sent, never in the store, is cleared after Save, and is never drawn back.
import { useCallback, useId, useState, type ReactNode } from "react";
import { useSettingsState, useStore } from "../context";
import { Select } from "../editors/Select";
import { Switch } from "../editors/ToggleEditor";
import type {
  DevicesDevice,
  DevicesLabels,
  DevicesRelay,
  DevicesRelayDraft,
  DevicesRelayMode,
  DevicesRun,
  DevicesRunResult,
  DevicesState,
  DevicesTone,
} from "../ops";

export function DevicesCard() {
  const store = useStore();
  const { devices } = useSettingsState();
  // Like Accounts: the host reads again when the card mounts (a stable callback ref runs once per mount).
  const mounted = useCallback(
    (node: HTMLDivElement | null) => {
      if (node) void store.runDevices({ action: "refresh" });
    },
    [store],
  );
  return (
    <div className="devices" data-card="devices" ref={mounted}>
      {devices && <DevicesBody state={devices} />}
    </div>
  );
}

/** One gesture with its failure kept for the control that sent it. */
function useRun(): [string | null, (run: DevicesRun) => Promise<DevicesRunResult>, (error: string | null) => void] {
  const store = useStore();
  const [error, setError] = useState<string | null>(null);
  const run = useCallback(
    async (gesture: DevicesRun) => {
      const result = await store.runDevices(gesture);
      setError(result.error ?? null);
      return result;
    },
    [store],
  );
  return [error, run, setError];
}

function RunError({ error }: { error: string | null }) {
  return error ? (
    <div className="row-error" data-devices-error="">
      {error}
    </div>
  ) : null;
}

function Status({ tone, children }: { tone: DevicesTone; children: ReactNode }) {
  return (
    <span className="accounts-status devices-status" data-tone={tone}>
      <span className="accounts-dot" aria-hidden="true" />
      {children}
    </span>
  );
}

function DevicesBody({ state }: { state: DevicesState }) {
  const [error, run] = useRun();
  const { labels } = state;
  const header = (
    <section className="group" data-devices-header="">
      <div className="accounts-header devices-header">
        <Status tone={state.status.tone}>
          <span data-devices-status="">{state.status.text}</span>
        </Status>
        {state.available && state.signIn && (
          <button
            type="button"
            className="button"
            data-devices-action="signIn"
            onClick={() => void run({ action: "signIn" })}
          >
            {state.signIn}
          </button>
        )}
        {state.available && (
          <button
            type="button"
            className="button"
            data-devices-action="refresh"
            onClick={() => void run({ action: "refresh" })}
          >
            {labels.refresh}
          </button>
        )}
      </div>
      {state.available && state.error && (
        <div className="row-error" data-devices-state-error="">
          {state.error}
        </div>
      )}
      <RunError error={error} />
    </section>
  );
  // Without a device hub in this build the card says so and nothing else.
  if (!state.available) return header;
  return (
    <>
      {header}
      {state.thisDevice && (
        <section className="group" data-devices-group="this">
          <h3 className="group-title">{state.labels.thisDeviceSection}</h3>
          <div className="rows">
            <DeviceRow device={state.thisDevice} labels={labels} />
          </div>
        </section>
      )}
      {state.sharing && <SharingGroup sharing={state.sharing} labels={labels} />}
      <section className="group" data-devices-group="others">
        <h3 className="group-title">{labels.othersSection}</h3>
        {state.others.length === 0 ? (
          <div className="row-help" data-devices-empty="others">
            {labels.noOthers}
          </div>
        ) : (
          <div className="rows">
            {state.others.map((device) => (
              <DeviceRow key={device.id} device={device} labels={labels} />
            ))}
          </div>
        )}
      </section>
      <RelaysGroup relays={state.relays} labels={labels} />
      <HistoryGroup state={state} />
    </>
  );
}

/** Removal and relay deletion ask first, inline, with the host's texts. */
function Confirm({
  title,
  body,
  confirm,
  cancel,
  onConfirm,
  onCancel,
}: {
  title: string;
  body: string;
  confirm: string;
  cancel: string;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  return (
    // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
    <div className="accounts-form" data-devices-confirm="" role="group" aria-label={title}>
      <div className="row-title">{title}</div>
      {body && <div className="row-help">{body}</div>}
      <div className="accounts-buttons">
        <button type="button" className="button danger" data-devices-confirm-action="confirm" onClick={onConfirm}>
          {confirm}
        </button>
        <button type="button" className="button" data-devices-confirm-action="cancel" onClick={onCancel}>
          {cancel}
        </button>
      </div>
    </div>
  );
}

function DeviceRow({ device, labels }: { device: DevicesDevice; labels: DevicesLabels }) {
  const store = useStore();
  const [error, run, setError] = useRun();
  const [mode, setMode] = useState<"rename" | "remove" | null>(null);
  const [name, setName] = useState(device.name);
  const titleId = useId();
  const rename = async () => {
    const result = await run({ action: "rename", id: device.id, name: name.trim() });
    if (!result.error) setMode(null);
  };
  const remove = async () => {
    const result = await run({ action: "remove", id: device.id });
    if (!result.error) setMode(null);
  };
  return (
    <div
      className="row accounts-row devices-device"
      data-device={device.id}
      data-this-device={device.thisDevice ? "" : undefined}
    >
      <div className="row-main">
        <div className="row-label">
          <div className="row-title devices-title" id={titleId}>
            <span data-device-name="">{device.name}</span>
            {device.thisDevice && (
              <span className="badge devices-badge" data-device-badge="">
                {labels.thisDeviceBadge}
              </span>
            )}
          </div>
          <div className="row-help">
            {device.platform}
            {!device.thisDevice && (
              <>
                {" · "}
                <Status tone={device.online ? "success" : "neutral"}>
                  <span data-device-presence={device.online ? "online" : "offline"}>{device.presence}</span>
                </Status>
              </>
            )}
          </div>
          {device.fingerprint && (
            <div className="row-help" data-device-fingerprint="">
              {labels.fingerprint}{" "}
              <code className="font-mono selectable" title={device.fingerprintFull ?? undefined}>
                {device.fingerprint}
              </code>
              {device.fingerprintFull && (
                <>
                  {" "}
                  <button
                    type="button"
                    className="button devices-copy"
                    data-device-copy-fingerprint=""
                    onClick={() => void store.copy(device.fingerprintFull!)}
                  >
                    {labels.copy}
                  </button>
                </>
              )}
            </div>
          )}
          {device.sharesText && (
            <div className="row-help" data-device-shares="">
              {device.sharesText}
            </div>
          )}
        </div>
        <div className="row-control">
          {!device.thisDevice && device.access !== null && (
            <span className="devices-access" data-device-access="">
              <span className="row-help" id={`${titleId}-access`}>
                {labels.access}
              </span>
              <Select
                value={device.access}
                disabled={false}
                labelId={`${titleId}-access`}
                onChange={(scope) =>
                  void run({ action: "setAccess", id: device.id, scope: scope as NonNullable<DevicesDevice["access"]> })
                }
              >
                {labels.accessOptions.map((option) => (
                  <option key={option.value} value={option.value}>
                    {option.title}
                  </option>
                ))}
              </Select>
            </span>
          )}
          <button
            type="button"
            className="button"
            data-device-action="rename"
            aria-describedby={titleId}
            onClick={() => {
              setName(device.name);
              setError(null);
              setMode("rename");
            }}
          >
            {labels.rename}
          </button>
          <button
            type="button"
            className="button danger"
            data-device-action="remove"
            aria-describedby={titleId}
            onClick={() => {
              setError(null);
              setMode("remove");
            }}
          >
            {labels.remove}
          </button>
        </div>
      </div>
      {mode === "rename" && (
        <form
          className="accounts-form devices-form"
          data-device-rename=""
          onSubmit={(event) => {
            event.preventDefault();
            if (name.trim()) void rename();
          }}
        >
          <div className="row-title">{labels.renameTitle}</div>
          <input
            className="field"
            type="text"
            aria-label={labels.nameField}
            placeholder={labels.nameField}
            value={name}
            onChange={(event) => setName(event.target.value)}
          />
          <div className="accounts-buttons">
            <button type="submit" className="button" data-device-action="saveName" disabled={!name.trim()}>
              {labels.save}
            </button>
            <button type="button" className="button" data-device-action="cancelRename" onClick={() => setMode(null)}>
              {labels.cancel}
            </button>
          </div>
        </form>
      )}
      {mode === "remove" && (
        <Confirm
          title={device.removeConfirm.title}
          body={device.removeConfirm.body}
          confirm={device.removeConfirm.confirm}
          cancel={labels.cancel}
          onConfirm={() => void remove()}
          onCancel={() => setMode(null)}
        />
      )}
      <RunError error={error} />
    </div>
  );
}

function SharingGroup({ sharing, labels }: { sharing: NonNullable<DevicesState["sharing"]>; labels: DevicesLabels }) {
  const [error, run] = useRun();
  const titleId = useId();
  return (
    <section className="group" data-devices-group="sharing">
      <h3 className="group-title">{labels.sharingSection}</h3>
      <div className="rows">
        <div className="row" data-devices-sharing="">
          <div className="row-main">
            <div className="row-label">
              <div className="row-title" id={titleId}>
                {labels.sharingToggle}
              </div>
              <div className="row-help">{labels.sharingDetail}</div>
            </div>
            <div className="row-control">
              <Switch
                checked={sharing.on}
                disabled={sharing.busy}
                labelId={titleId}
                onToggle={(on) => void run({ action: "setSharing", on })}
              />
            </div>
          </div>
          <RunError error={error} />
        </div>
        {sharing.on &&
          sharing.permissions.map((permission) => (
            <div className="row" key={permission.id} data-devices-permission={permission.id}>
              <div className="row-main">
                <div className="row-label">
                  <div className="row-title">{permission.title}</div>
                  <div className="row-help">{permission.detail}</div>
                </div>
                <div className="row-control">
                  {permission.granted ? (
                    <Status tone="success">{labels.allowed}</Status>
                  ) : (
                    <button
                      type="button"
                      className="button"
                      data-devices-action="openPermission"
                      onClick={() => void run({ action: "openPermission", id: permission.id })}
                    >
                      {labels.openSettings}
                    </button>
                  )}
                </div>
              </div>
            </div>
          ))}
      </div>
    </section>
  );
}

function RelaysGroup({ relays, labels }: { relays: DevicesRelay[]; labels: DevicesLabels }) {
  // `null`: no editor; `"new"`: Add Relay…; else the id of the relay being edited.
  const [editing, setEditing] = useState<string | null>(null);
  const edited = editing && editing !== "new" ? (relays.find((relay) => relay.id === editing) ?? null) : null;
  return (
    <section className="group" data-devices-group="relays">
      <h3 className="group-title">{labels.relaysSection}</h3>
      <div className="accounts-header devices-relays-header">
        <div className="row-help devices-relays-help">{labels.relaysHelp}</div>
        <button
          type="button"
          className="button"
          data-devices-action="addRelay"
          disabled={editing === "new"}
          onClick={() => setEditing("new")}
        >
          {labels.addRelay}
        </button>
      </div>
      {editing === "new" && <RelayEditor key="new" relay={null} labels={labels} onDone={() => setEditing(null)} />}
      {relays.length === 0 ? (
        <div className="row-help" data-devices-empty="relays">
          {labels.relaysEmpty}
        </div>
      ) : (
        <div className="rows">
          {relays.map((relay) => (
            <RelayRow key={relay.id} relay={relay} labels={labels} onEdit={() => setEditing(relay.id)}>
              {edited?.id === relay.id && (
                <RelayEditor key={relay.id} relay={relay} labels={labels} onDone={() => setEditing(null)} />
              )}
            </RelayRow>
          ))}
        </div>
      )}
    </section>
  );
}

function RelayRow({
  relay,
  labels,
  onEdit,
  children,
}: {
  relay: DevicesRelay;
  labels: DevicesLabels;
  onEdit: () => void;
  children: ReactNode;
}) {
  const [error, run, setError] = useRun();
  const [confirming, setConfirming] = useState(false);
  const [checked, setChecked] = useState<string | null>(null);
  const titleId = useId();
  const check = async () => {
    setChecked(null);
    const result = await run({ action: "checkRelay", id: relay.id });
    setChecked(result.text ?? null);
  };
  const remove = async () => {
    const result = await run({ action: "deleteRelay", id: relay.id });
    if (!result.error) setConfirming(false);
  };
  return (
    <div className="row accounts-row" data-relay={relay.id}>
      <div className="row-main">
        <div className="row-label">
          <div className="row-title devices-title" id={titleId}>
            <span>{relay.name}</span>
            {!relay.enabled && (
              <span className="badge devices-badge" data-relay-off="">
                {labels.relayOff}
              </span>
            )}
          </div>
          <div className="row-help selectable" data-relay-urls="">
            {relay.urls.join(", ")}
          </div>
          <div className="row-help">{relay.modeText}</div>
          {checked !== null ? (
            <div className="row-help" data-relay-check="">
              {checked}
            </div>
          ) : (
            relay.check && (
              <div className={relay.check.tone === "danger" ? "row-error" : "row-help"} data-relay-check="">
                <Status tone={relay.check.tone}>{relay.check.text}</Status>
              </div>
            )
          )}
        </div>
        <div className="row-control">
          <button
            type="button"
            className="button"
            data-relay-action="check"
            aria-describedby={titleId}
            disabled={relay.checking || !relay.hasSecret}
            onClick={() => void check()}
          >
            {labels.checkRelay}
          </button>
          <button type="button" className="button" data-relay-action="edit" aria-describedby={titleId} onClick={onEdit}>
            {labels.editRelay}
          </button>
          <button
            type="button"
            className="button danger"
            data-relay-action="delete"
            aria-describedby={titleId}
            onClick={() => {
              setError(null);
              setConfirming(true);
            }}
          >
            {labels.deleteRelay}
          </button>
        </div>
      </div>
      {confirming && (
        <Confirm
          title={labels.deleteRelayTitle}
          body={labels.deleteRelayBody}
          confirm={labels.deleteRelay}
          cancel={labels.cancel}
          onConfirm={() => void remove()}
          onCancel={() => setConfirming(false)}
        />
      )}
      {children}
      <RunError error={error} />
    </div>
  );
}

/** The relay URLs as typed: one per line or comma separated, trimmed, blanks dropped. */
export function relayURLs(text: string): string[] {
  return text
    .split(/[\n,]/)
    .map((url) => url.trim())
    .filter((url) => url !== "");
}

/** Add Relay… (`relay` null) or Edit… of one relay. Credentials are only ever typed here: an empty
 * secret (or username and password) on edit keeps the saved one, so the draft leaves it out. */
function RelayEditor({
  relay,
  labels,
  onDone,
}: {
  relay: DevicesRelay | null;
  labels: DevicesLabels;
  onDone: () => void;
}) {
  const [error, run] = useRun();
  const [name, setName] = useState(relay?.name ?? "");
  const [urls, setUrls] = useState(relay?.urls.join("\n") ?? "");
  const [mode, setMode] = useState<DevicesRelayMode>(relay?.mode ?? labels.modeOptions[0]?.value ?? "shared_secret");
  const [secret, setSecret] = useState("");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [enabled, setEnabled] = useState(relay?.enabled ?? true);
  const [priority, setPriority] = useState(String(relay?.priority ?? 0));
  const [checked, setChecked] = useState<string | null>(null);
  const enabledId = useId();
  const modeId = useId();
  const urlsHelpId = useId();
  const priorityHelpId = useId();
  const editing = relay !== null;
  const draft = (): DevicesRelayDraft => {
    const out: DevicesRelayDraft = {
      name: name.trim(),
      urls: relayURLs(urls),
      mode,
      enabled,
      priority: Number.parseInt(priority, 10) || 0,
    };
    if (relay) out.id = relay.id;
    if (mode === "shared_secret") {
      if (secret !== "") out.secret = secret;
    } else if (username !== "" || password !== "") {
      out.username = username;
      out.password = password;
    }
    return out;
  };
  const clearSecrets = () => {
    setSecret("");
    setUsername("");
    setPassword("");
  };
  const save = async () => {
    const relayDraft = draft();
    clearSecrets();
    const result = await run({ action: "saveRelay", relay: relayDraft });
    if (!result.error) onDone();
  };
  const check = async () => {
    setChecked(null);
    // On edit the id lets the host use the saved secret when none is typed.
    const relayDraft = draft();
    const result = await run(
      relay ? { action: "checkRelay", id: relay.id, relay: relayDraft } : { action: "checkRelay", relay: relayDraft },
    );
    setChecked(result.text ?? null);
  };
  const keep = editing ? labels.relaySecretKeep : undefined;
  return (
    <form
      className="accounts-form devices-form"
      data-relay-editor={relay?.id ?? "new"}
      onSubmit={(event) => {
        event.preventDefault();
        void save();
      }}
    >
      <div className="row-title">{editing ? labels.editRelay : labels.addRelay}</div>
      <label className="devices-field">
        <span className="row-help">{labels.relayName}</span>
        <input
          className="field"
          type="text"
          data-relay-field="name"
          aria-label={labels.relayName}
          value={name}
          onChange={(event) => setName(event.target.value)}
        />
      </label>
      <label className="devices-field">
        <span className="row-help">{labels.relayURLs}</span>
        <textarea
          className="field devices-urls font-mono"
          data-relay-field="urls"
          aria-label={labels.relayURLs}
          aria-describedby={urlsHelpId}
          rows={3}
          spellCheck={false}
          value={urls}
          onChange={(event) => setUrls(event.target.value)}
        />
        <span className="row-help" id={urlsHelpId}>
          {labels.relayURLsHelp}
        </span>
      </label>
      <div className="devices-field" data-relay-field="mode">
        <span className="row-help" id={modeId}>
          {labels.relayMode}
        </span>
        <Select value={mode} disabled={false} labelId={modeId} onChange={(value) => setMode(value as DevicesRelayMode)}>
          {labels.modeOptions.map((option) => (
            <option key={option.value} value={option.value}>
              {option.title}
            </option>
          ))}
        </Select>
      </div>
      {mode === "shared_secret" ? (
        <label className="devices-field">
          <span className="row-help">{labels.relaySecret}</span>
          <input
            className="field"
            type="password"
            autoComplete="off"
            data-relay-field="secret"
            aria-label={labels.relaySecret}
            placeholder={keep}
            value={secret}
            onChange={(event) => setSecret(event.target.value)}
          />
        </label>
      ) : (
        <>
          <label className="devices-field">
            <span className="row-help">{labels.relayUsername}</span>
            <input
              className="field"
              type="text"
              autoComplete="off"
              spellCheck={false}
              data-relay-field="username"
              aria-label={labels.relayUsername}
              placeholder={keep}
              value={username}
              onChange={(event) => setUsername(event.target.value)}
            />
          </label>
          <label className="devices-field">
            <span className="row-help">{labels.relayPassword}</span>
            <input
              className="field"
              type="password"
              autoComplete="off"
              data-relay-field="password"
              aria-label={labels.relayPassword}
              placeholder={keep}
              value={password}
              onChange={(event) => setPassword(event.target.value)}
            />
          </label>
        </>
      )}
      <div className="devices-field devices-field-inline" data-relay-field="enabled">
        <span className="row-help" id={enabledId}>
          {labels.relayEnabled}
        </span>
        <Switch checked={enabled} disabled={false} labelId={enabledId} onToggle={setEnabled} />
      </div>
      <label className="devices-field">
        <span className="row-help">{labels.relayPriority}</span>
        <input
          className="field devices-priority"
          type="number"
          step={1}
          data-relay-field="priority"
          aria-label={labels.relayPriority}
          aria-describedby={priorityHelpId}
          value={priority}
          onChange={(event) => setPriority(event.target.value)}
        />
        <span className="row-help" id={priorityHelpId}>
          {labels.relayPriorityHelp}
        </span>
      </label>
      {checked !== null && (
        <div className="row-help" data-relay-check="">
          {checked}
        </div>
      )}
      <RunError error={error} />
      <div className="accounts-buttons">
        <button
          type="submit"
          className="button"
          data-relay-action="save"
          disabled={name.trim() === "" || relayURLs(urls).length === 0}
        >
          {labels.save}
        </button>
        <button
          type="button"
          className="button"
          data-relay-action="checkDraft"
          disabled={relayURLs(urls).length === 0}
          onClick={() => void check()}
        >
          {labels.checkRelay}
        </button>
        <button type="button" className="button" data-relay-action="cancel" onClick={onDone}>
          {labels.cancel}
        </button>
      </div>
    </form>
  );
}

function HistoryGroup({ state }: { state: DevicesState }) {
  const { labels } = state;
  const columns = labels.historyColumns;
  return (
    <section className="group" data-devices-group="history">
      <h3 className="group-title">{labels.historySection}</h3>
      {state.history.length === 0 ? (
        <div className="row-help" data-devices-empty="history">
          {labels.historyEmpty}
        </div>
      ) : (
        <div className="rows devices-history-scroll">
          <table className="devices-history devices-history-fixed">
            {/* Fixed columns keep the table inside its card at any page width. */}
            <colgroup>
              <col className="devices-col-time" />
              <col className="devices-col-event" />
              <col className="devices-col-device" />
              <col className="devices-col-device" />
              <col className="devices-col-scope" />
              <col className="devices-col-detail" />
              <col className="devices-col-duration" />
            </colgroup>
            <thead>
              <tr>
                <th scope="col">{columns.time}</th>
                <th scope="col">{columns.event}</th>
                <th scope="col">{columns.device}</th>
                <th scope="col">{columns.host}</th>
                <th scope="col">{columns.scope}</th>
                <th scope="col">{columns.detail}</th>
                <th scope="col">{columns.duration}</th>
              </tr>
            </thead>
            <tbody>
              {state.history.map((row) => (
                <tr key={row.id} data-history={row.id}>
                  <td className="devices-time">{row.time}</td>
                  <td>
                    <span className="devices-pill" data-tone={row.tone} data-event={row.event}>
                      {row.eventText}
                    </span>
                  </td>
                  <td className="devices-wrap" title={row.device}>
                    {row.device}
                  </td>
                  <td className="devices-wrap" title={row.host}>
                    {row.host}
                  </td>
                  <td>{row.scope}</td>
                  <td className="devices-wrap devices-detail" title={row.detail}>
                    {row.detail}
                  </td>
                  <td className="devices-nowrap">{row.duration}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}
