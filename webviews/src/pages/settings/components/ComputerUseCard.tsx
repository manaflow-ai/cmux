// Settings > Computer Use: every cmux Computer Use setting on one page. cmux Computer Use is built
// in, so the card leads with one line saying no install is needed, then the status (engine,
// macOS permissions with Grant buttons that run the shared catalog actions, the worker), the mode
// with a plain line per choice, the denied apps, the saved approvals and the switches. The status
// comes from the host lists' `computer_use`, live through cmux.settings.host.changed; every
// setting is a schema row (`settings.group.computerUse`), which SectionView does not draw a
// second time (COMPUTER_USE_ROWS).
import { useId, useState } from "react";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { useRowState, useSettingsState, useStore } from "../context";
import { Select } from "../editors/Select";
import { Icon } from "../icons";
import type { ComputerUseApproval, ComputerUseState, SettingsPageAction } from "../ops";
import { rowsByKey } from "../schema";
import { t, text } from "../strings";
import { ActionRow } from "./ActionRow";
import { RowFrame, RowStatus, SettingRow } from "./SettingRow";

export const COMPUTER_USE_MODE = "computerUse.mode";
export const COMPUTER_USE_DENIED_APPS = "computerUse.deniedApps";
/** Whether agents may open menus of background apps (a choice row, drawn before the switches). */
export const COMPUTER_USE_MENUS = "computerUse.menus";
/** The switches, in the card's order; Allow Foreground Input (advanced) comes last. */
export const COMPUTER_USE_SWITCHES = [
  "computerUse.allowOwnMachines",
  "computerUse.pauseOnTakeover",
  "computerUse.showCursor",
  "computerUse.livePreview",
  "computerUse.allowForeground",
] as const;

/** The schema rows the card draws itself. */
export const COMPUTER_USE_ROWS: ReadonlySet<string> = new Set([
  COMPUTER_USE_MODE,
  COMPUTER_USE_DENIED_APPS,
  COMPUTER_USE_MENUS,
  ...COMPUTER_USE_SWITCHES,
]);

/** The modes in the order the picker lists them: most access first. */
export const COMPUTER_USE_MODES = ["fullAccess", "approvedApps", "askEveryTime", "lookOnly", "off"] as const;

function statusText(state: ComputerUseState): string {
  if (state.phase === "ready") {
    return state.accessibility && state.screen_recording
      ? t("settingsWindow.computerUse.phase.ready")
      : t("settingsWindow.computerUse.phase.missing");
  }
  return t(`settingsWindow.computerUse.phase.${state.phase}`);
}

function Grant({ granted }: { granted: boolean | null }) {
  if (granted === null) return <span className="badge">{t("settingsWindow.computerUse.unknown")}</span>;
  return granted ? (
    <span className="badge" data-granted="true">
      {t("settingsWindow.computerUse.allowed")}
    </span>
  ) : (
    <span className="badge badge-warning" data-granted="false">
      {t("settingsWindow.computerUse.notAllowed")}
    </span>
  );
}

type Run = (action: SettingsPageAction, args?: Record<string, unknown>) => void;

/** Engine, permissions and worker. A policy lock or Off leaves only the status line. */
function StatusRows({ state, mode, run }: { state: ComputerUseState | null; mode: unknown; run: Run }) {
  const locked = state?.phase === "disabled_by_policy";
  const failed = state?.phase === "failed";
  const off = mode === "off" || state?.phase === "off";
  const grant = (
    pane: "accessibility" | "screenRecording",
    granted: boolean | null,
    action: "palette.computerUse.accessibility" | "palette.computerUse.screenRecording",
  ) => (
    <ActionRow title={t(`settingsWindow.computerUse.${pane}`)} help={t(`settingsWindow.computerUse.${pane}.help`)}>
      <Grant granted={granted} />
      {granted !== true && (
        <Button type="button" className="button" data-action={action} onClick={() => run(action)}>
          {t("settingsWindow.computerUse.grant")}
        </Button>
      )}
    </ActionRow>
  );
  const worker = state?.worker;
  return (
    <>
      <ActionRow
        title={t("settingsWindow.computerUse.engine")}
        help={
          off
            ? t("settingsWindow.computerUse.statusOff")
            : state
              ? statusText(state)
              : t("settingsWindow.computerUse.phase.starting")
        }
      >
        {state?.engine && <span className="badge">{state.engine}</span>}
        {failed && (
          <Button
            type="button"
            className="button"
            data-action="palette.computerUse.restart"
            onClick={() => run("palette.computerUse.restart")}
          >
            {t("settingsWindow.computerUse.restartWorker")}
          </Button>
        )}
      </ActionRow>
      {state && !locked && !failed && !off && (
        <>
          {grant("accessibility", state.accessibility, "palette.computerUse.accessibility")}
          {grant("screenRecording", state.screen_recording, "palette.computerUse.screenRecording")}
        </>
      )}
      {worker && !locked && !off && (
        <ActionRow
          title={t("settingsWindow.computerUse.worker")}
          help={
            worker.pid != null && worker.state === "running"
              ? t("settingsWindow.computerUse.workerPid", worker.pid)
              : ""
          }
        >
          <span className="badge" data-worker={worker.state}>
            {t(`settingsWindow.computerUse.worker.${worker.state}`)}
          </span>
        </ActionRow>
      )}
    </>
  );
}

/** The mode: one radio per mode, each with its plain line. */
function ModePicker({ focused }: { focused: boolean }) {
  const store = useStore();
  const row = rowsByKey.get(COMPUTER_USE_MODE);
  const state = useRowState(COMPUTER_USE_MODE);
  const labelId = useId();
  if (!row) return null;
  const disabled = !state.connected || !state.readable || state.managed !== null;
  const titles = new Map((row.choices ?? []).map((choice) => [choice.value, text(choice.title)]));
  return (
    <RowFrame settingKey={row.key} kind="computer-use-mode" state={state}>
      <div className="row-main computer-use-mode-main">
        <div className="row-label">
          <div className="row-title" id={labelId}>
            {text(row.title)}
          </div>
          {row.summary && <div className="row-help">{text(row.summary)}</div>}
          <RowStatus settingKey={row.key} state={state} />
        </div>
      </div>
      <fieldset className="computer-use-modes" aria-labelledby={labelId} data-focused={focused ? "" : undefined}>
        {COMPUTER_USE_MODES.map((mode) => (
          <label
            key={mode}
            className="computer-use-mode"
            data-mode={mode}
            data-checked={state.value === mode ? "" : undefined}
          >
            <input
              type="radio"
              name={`${labelId}-mode`}
              aria-label={titles.get(mode) ?? mode}
              value={mode}
              checked={state.value === mode}
              disabled={disabled}
              onChange={() => void store.set(row.key, mode)}
            />
            <span className="computer-use-mode-text">
              <span className="computer-use-mode-title">{titles.get(mode) ?? mode}</span>
              <span className="row-help">{t(`settingsWindow.computerUse.mode.${mode}.line`)}</span>
            </span>
          </label>
        ))}
      </fieldset>
    </RowFrame>
  );
}

/** Denied Apps: the list with Remove, Add by a running app or a typed id, Restore Defaults. */
function DeniedApps({ runningApps }: { runningApps: Array<{ id: string; name: string }> }) {
  const store = useStore();
  const row = rowsByKey.get(COMPUTER_USE_DENIED_APPS);
  const state = useRowState(COMPUTER_USE_DENIED_APPS);
  const labelId = useId();
  const [draft, setDraft] = useState("");
  if (!row) return null;
  const disabled = !state.connected || !state.readable || state.managed !== null;
  const apps = Array.isArray(state.value) ? state.value.map(String) : [];
  const write = (next: string[]) => void store.set(row.key, next);
  const add = (id: string) => {
    const app = id.trim();
    if (app === "" || apps.includes(app)) return;
    write([...apps, app]);
  };
  const names = new Map(runningApps.map((app) => [app.id, app.name]));
  const offered = runningApps.filter((app) => !apps.includes(app.id));
  return (
    <RowFrame settingKey={row.key} kind="computer-use-denied" state={state}>
      <div className="row-main">
        <div className="row-label">
          <div className="row-title" id={labelId}>
            {text(row.title)}
          </div>
          {row.summary && <div className="row-help">{text(row.summary)}</div>}
          <RowStatus settingKey={row.key} state={state} />
        </div>
        <div className="row-control action-row-control">
          <Button
            type="button"
            className="button"
            data-denied-restore=""
            disabled={disabled || !state.customized}
            onClick={() => void store.reset(row.key)}
          >
            {t("settingsWindow.computerUse.restoreDefaults")}
          </Button>
        </div>
      </div>
      <ul className="computer-use-list" aria-labelledby={labelId} data-denied-list="">
        {apps.length === 0 && <li className="row-help">{t("settingsWindow.computerUse.deniedEmpty")}</li>}
        {apps.map((app) => (
          <li key={app} className="computer-use-list-row" data-denied-app={app}>
            <span className="computer-use-app">
              {names.get(app) && <span className="computer-use-app-name">{names.get(app)}</span>}
              <span className="computer-use-app-id">{app}</span>
            </span>
            <Button
              type="button"
              icon
              size="sm"
              variant="ghost"
              aria-label={`${t("settingsPage.remove")} ${app}`}
              disabled={disabled}
              onClick={() => write(apps.filter((item) => item !== app))}
            >
              <Icon name="xmark" />
            </Button>
          </li>
        ))}
      </ul>
      <div className="computer-use-add">
        {offered.length > 0 && (
          <Select value="" disabled={disabled} labelId={labelId} onChange={(id) => add(id)}>
            <option value="" disabled>
              {t("settingsWindow.computerUse.addRunningApp")}
            </option>
            {offered.map((app) => (
              <option key={app.id} value={app.id}>
                {app.name}
              </option>
            ))}
          </Select>
        )}
        <Input
          className="field"
          type="text"
          spellCheck={false}
          value={draft}
          placeholder={t("settingsWindow.computerUse.appIdPlaceholder")}
          disabled={disabled}
          aria-label={t("settingsWindow.computerUse.appIdPlaceholder")}
          data-denied-input=""
          onChange={(event) => setDraft(event.currentTarget.value)}
          onKeyDown={(event) => {
            if (event.key !== "Enter") return;
            event.preventDefault();
            add(draft);
            setDraft("");
          }}
        />
        <Button
          type="button"
          className="button"
          data-denied-add=""
          disabled={disabled || draft.trim() === ""}
          onClick={() => {
            add(draft);
            setDraft("");
          }}
        >
          {t("settingsPage.add")}
        </Button>
      </div>
    </RowFrame>
  );
}

/** Saved Approvals: each app's Always allow or Never, changeable, with Forget. */
function Approvals({ approvals, run, disabled }: { approvals: ComputerUseApproval[]; run: Run; disabled: boolean }) {
  const labelId = useId();
  return (
    <div className="row" data-approvals="" tabIndex={-1}>
      <div className="row-main">
        <div className="row-label">
          <div className="row-title" id={labelId}>
            {t("settingsWindow.computerUse.approvals")}
          </div>
          <div className="row-help">
            {approvals.length === 0
              ? t("settingsWindow.computerUse.approvalsEmpty")
              : t("settingsWindow.computerUse.approvals.help")}
          </div>
        </div>
      </div>
      {approvals.length > 0 && (
        <ul className="computer-use-list" aria-labelledby={labelId}>
          {approvals.map((approval) => (
            <li key={approval.app_id} className="computer-use-list-row" data-approval={approval.app_id}>
              <span className="computer-use-app">
                <span className="computer-use-app-name">{approval.name}</span>
                <span className="computer-use-app-id">{approval.app_id}</span>
              </span>
              <span className="computer-use-approval-controls">
                <fieldset className="segmented" aria-label={approval.name}>
                  {(["always", "never"] as const).map((decision) => (
                    <label
                      key={decision}
                      className="segment"
                      data-checked={approval.decision === decision ? "" : undefined}
                    >
                      <input
                        type="radio"
                        name={`${labelId}-${approval.app_id}`}
                        aria-label={t(`settingsWindow.computerUse.approval.${decision}`)}
                        value={decision}
                        checked={approval.decision === decision}
                        disabled={disabled}
                        onChange={() => run("computerUse.approval.set", { app_id: approval.app_id, decision })}
                      />
                      {t(`settingsWindow.computerUse.approval.${decision}`)}
                    </label>
                  ))}
                </fieldset>
                <Button
                  type="button"
                  className="button"
                  data-forget={approval.app_id}
                  disabled={disabled}
                  onClick={() => run("computerUse.approval.forget", { app_id: approval.app_id })}
                >
                  {t("settingsWindow.computerUse.forget")}
                </Button>
              </span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

export function ComputerUseCard({ focus = null }: { focus?: string | null }) {
  const store = useStore();
  const { host } = useSettingsState();
  const state = host?.computer_use ?? null;
  const mode = useRowState(COMPUTER_USE_MODE);
  const run: Run = (action, args = {}) => void store.runAction(action, args);
  const locked = state?.phase === "disabled_by_policy";
  const row = (key: string) => {
    const schemaRow = rowsByKey.get(key);
    return schemaRow ? <SettingRow key={key} row={schemaRow} focused={focus === key} /> : null;
  };
  return (
    <section className="group" data-card="computer-use" data-phase={state?.phase ?? "unknown"}>
      <h3 className="group-title">{t("settings.group.computerUse")}</h3>
      <p className="computer-use-builtin" data-builtin="">
        {t("settingsWindow.computerUse.builtIn")}
      </p>
      <div className="rows">
        <StatusRows state={state} mode={mode.value} run={run} />
        <ModePicker focused={focus === COMPUTER_USE_MODE} />
        <DeniedApps runningApps={state?.running_apps ?? []} />
        <Approvals
          approvals={state?.approvals ?? []}
          run={run}
          disabled={locked || !mode.connected || mode.value === "off"}
        />
        {row(COMPUTER_USE_MENUS)}
        {COMPUTER_USE_SWITCHES.map(row)}
      </div>
    </section>
  );
}
