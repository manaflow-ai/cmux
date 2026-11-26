import { useSearch } from "@tanstack/react-router";
import { useEffect, useId, useLayoutEffect, useRef, useState } from "react";
import { Skeleton } from "../../../ui/Skeleton";
import { useSettingsState, useStore } from "../context";
import { Switch } from "../editors/ToggleEditor";
import { agentBrandSpec } from "../../../agent-session/shared/agentBrands.generated";
import { CLOUD_CHATGPT_SIGN_IN_READY } from "../../../agent-session/shared/cloudModelConnections";
import {
  canAddProvider,
  cloudProviderForFamily,
  providerById,
  providerDisabledReason,
  providerName,
} from "../providerCatalog";
import type { ModelConnection } from "../ops";
import { revealRow } from "../keyboard";
import { CLOUD_MODELS_ADD_FOCUS, CLOUD_MODELS_FOCUS, MODELS_ADD_FOCUS, type SettingsSearch } from "../router";
import { t } from "../strings";
import { GroupHeader } from "./GroupHeader";
import { ModelConnectionDialog } from "./ModelConnectionDialog";
import { ModelConnectionRow, ModelRow, type RowAction } from "./ModelConnectionRow";
import { ModelProviderPicker } from "./ModelProviderPicker";
import { MembersSection, OrganizationSection, sharedModelKeyName } from "./ModelsTeamSections";
import { SettingsErrorRow } from "./SettingsErrorRow";
import {
  isCloudSubscription,
  isLocalOnlyPlan,
  moveId,
  providerFamily,
  tokenTimeRemaining,
  useModelsRun,
  type Run,
  type SetupSelection,
} from "./modelConnections";

type Selection = (SetupSelection | RowAction) & { returnTo?: HTMLElement };
type SetupVisit = { request: string; ids: Set<string>; connected: boolean };
const skeletonRows = [0, 1, 2];

export function ModelsCard({ focus }: { focus: string | null }) {
  return <ModelConnectionsCard focus={focus} cloud={false} />;
}

export function CloudModelsCard({ focus, reveal }: { focus: string | null; reveal: boolean }) {
  return <ModelConnectionsCard focus={focus} cloud reveal={reveal} />;
}

function ModelConnectionsCard({ focus, cloud, reveal }: { focus: string | null; cloud: boolean; reveal?: boolean }) {
  const { models, modelsSettled } = useSettingsState();
  const search = useSearch({ strict: false }) as SettingsSearch;
  const { open } = search;
  const fromSend = cloud && search.fromSend;
  const family = cloud ? search.provider?.trim().toLowerCase() : undefined;
  const machine = family === "claude" ? search.machine : undefined;
  const environment = family === "claude" ? search.environment : undefined;
  const machineName = family === "claude" && !machine ? search.machineName : undefined;
  const recoverySession = family === "claude" && machine ? search.recoverySession : undefined;
  const request = JSON.stringify([focus, family, open, fromSend, machine, environment, recoverySession, machineName]);
  const add = cloud ? CLOUD_MODELS_ADD_FOCUS : MODELS_ADD_FOCUS;
  const addFocus = focus?.startsWith(add + ".") ? focus.slice(add.length + 1).split(".", 1)[0] : undefined;

  const available = models?.personal.available === true;
  const loading = !available && !modelsSettled;
  const store = useStore();
  const { busy, error, run, clearError } = useModelsRun();
  const [saving, setSaving] = useState(false);
  const [selection, setSelection] = useState<Selection | null>(null);
  const [pickerOpen, setPickerOpen] = useState(false);
  const [handled, setHandled] = useState<string | null>(null);
  const [setupVisit, setSetupVisit] = useState<SetupVisit | null>(null);
  const [checkedNamedVisit, setCheckedNamedVisit] = useState<string | null>(null);
  const [formError, setFormError] = useState(false);
  const spreadId = useId();
  const section = useRef<HTMLElement>(null);
  const addButton = useRef<HTMLButtonElement>(null);
  const returnFocus = useRef<HTMLElement | null>(null);
  const startingDevice = useRef(false);
  const locked = busy || saving;
  const connections = models?.personal.connections ?? [];
  const cloudRows = connections.filter(
    (c) =>
      c.kind !== "endpoint" &&
      c.provider !== "openrouter" &&
      !isLocalOnlyPlan(c) &&
      (isCloudSubscription(c) || (c.canServeCloud ?? c.servesCloud)),
  );
  const routeRows = cloud ? cloudRows : connections.filter((c) => c.kind !== "native-login");
  const cloudTeamKeys = cloud && models?.organization.team ? models.organization.keys.filter((key) => key.set) : [];
  const cloudClaude = models?.cloudClaudeLogin;
  const namedVisit = machineName ? request : null;
  const explicitVisit = machine ? request : null;
  const claudeLogin = cloud
    ? (!namedVisit || checkedNamedVisit === namedVisit) &&
      (!machine || !cloudClaude?.machine || cloudClaude.machine === machine) &&
      (!environment ||
        (!cloudClaude?.machine && !cloudClaude?.environment) ||
        cloudClaude.environment === environment) &&
      (!machineName || (!cloudClaude?.machine && !cloudClaude?.machineName) || cloudClaude.machineName === machineName)
      ? cloudClaude
      : undefined
    : models?.claudeLogin;
  const claudeConnected = cloud && claudeLogin?.phase === "connected" && !!claudeLogin.machine;
  const nativeCloud: ModelConnection | undefined =
    claudeConnected || (cloud && claudeLogin?.phase === "failed" && claudeLogin.signedIn && claudeLogin.machine)
      ? {
          id: "claude-cloud-login",
          kind: "claude-login",
          provider: "anthropic",
          families: ["claude"],
          label: "Claude Code",
          signedIn: true,
          servesCloud: true,
          enabled: true,
          email: null,
          plan: null,
          defaultFor: [],
        }
      : undefined;
  const displayed = cloud
    ? [...(nativeCloud ? [nativeCloud] : []), ...routeRows]
    : [...routeRows, ...connections.filter((c) => c.kind === "native-login")];
  const claudeAvailable = models?.claudeCodeAvailable;
  const cloudClaudeMachine = cloud && !namedVisit && claudeLogin?.machineName;
  useEffect(() => {
    if (available && (cloud || claudeAvailable !== false)) {
      const checked = store.runModels({
        action: "checkClaudeLogin",
        cloud,
        ...(machine ? { machine } : {}),
        ...(environment ? { environment } : {}),
        ...(machineName ? { machineName } : {}),
      });
      if (namedVisit) {
        let current = true;
        void checked.then(async ({ failure }) => {
          if (!current || failure !== null) return;
          if ((await store.refreshModels()) && current) setCheckedNamedVisit(namedVisit);
        });
        return () => {
          current = false;
        };
      }
    }
  }, [
    available,
    cloud,
    claudeAvailable,
    cloudClaudeMachine,
    machine,
    environment,
    machineName,
    namedVisit,
    explicitVisit,
    store,
  ]);
  const now = Date.now();
  const cloudRunnerStatus = (connection: ModelConnection): "updating" | "offline" | "notReady" | undefined => {
    const runner = connection.launchHarness;
    if (!runner) return undefined;
    if (models?.cloudHarnesses?.includes(runner)) return undefined;
    if (models?.cloudEndpointRunnersPending) return "updating";
    return models?.cloudRunnersOffline ? "offline" : "notReady";
  };
  const usable = (c: ModelConnection) => c.enabled && c.signedIn && tokenTimeRemaining(c, now) > 0;
  const ready = cloudRows.filter((c) => c.servesCloud && usable(c) && !cloudRunnerStatus(c));
  const servesFamily = (c: ModelConnection, family: string) => (c.cloudFamilies ?? c.families).includes(family);
  const canToggleCloud = (c: ModelConnection) =>
    c.kind === "api-key" && !!c.credentialInstance && !!c.keyRevision && (c.canServeCloud ?? c.servesCloud);
  const cloudOff =
    family && !machine && !machineName && !environment && !ready.some((c) => servesFamily(c, family))
      ? cloudRows.find((c) => canToggleCloud(c) && !c.servesCloud && usable(c) && servesFamily(c, family))
      : undefined;
  const targetFor = (id: string) => {
    if (id === "kimi-code") return connections.find((c) => c.kind === "kimi-plan")?.id;
    const provider = providerById(id);
    if (!provider || (provider.kind !== "subscription" && provider.kind !== "claude-login")) return undefined;
    const family = providerFamily(provider);
    if (!family) return undefined;
    const matches = (c: ModelConnection) => isCloudSubscription(c) && servesFamily(c, family);
    return (ready.find(matches) ?? cloudRows.find(matches))?.id;
  };
  const requestedId = family
    ? family === "codex" && fromSend && !CLOUD_CHATGPT_SIGN_IN_READY
      ? "openai"
      : cloudProviderForFamily(family)
    : addFocus;
  const requested = requestedId ? providerById(requestedId) : undefined;
  const requestedDisabled =
    requested && providerDisabledReason(requested, models?.claudeCodeAvailable, cloud, models?.claudeLogin?.error);
  const device = models?.chatgptDevice?.phase;
  const deviceProvider = models?.deviceProvider ?? "chatgpt";
  const devicePreset = deviceProvider === "kimi" ? "kimi-code" : deviceProvider;
  const capture = (cloud ? cloudClaude : claudeLogin)?.phase;
  const devicePending = device === "starting" || device === "waiting" || device === "cancelling";
  const claudePending =
    capture === "preparing" || capture === "approving" || capture === "code" || capture === "cancelling";
  const menuKey = (c: ModelConnection) =>
    cloud ? `${c.id}:${c.credentialInstance ?? ""}:${c.keyRevision ?? ""}` : c.id;
  const [openMenuKey, setOpenMenuKey] = useState<string | null>(null);
  useLayoutEffect(() => {
    if (reveal && !family) revealRow(section.current);
  }, [reveal, family, open]);
  if (available && handled !== request && !locked) {
    setHandled(request);
    setCheckedNamedVisit(null);
    setFormError(false);
    setOpenMenuKey(cloudOff ? menuKey(cloudOff) : null);
    setPickerOpen((focus === add && !family) || !!requestedDisabled);
    const resume = !family && (!focus || (cloud && focus === CLOUD_MODELS_FOCUS));
    const id =
      !cloudOff && requested && !requestedDisabled && canAddProvider(requested, cloud)
        ? requested.id
        : resume && devicePending && (!cloud || deviceProvider === "chatgpt")
          ? devicePreset
          : resume && claudePending && claudeLogin
            ? "claude"
            : undefined;
    const resumingDevice = id === devicePreset && devicePending;
    setSelection(
      id
        ? {
            id,
            target: resumingDevice
              ? (models?.deviceTarget ?? undefined)
              : family && family !== "claude"
                ? targetFor(id)
                : undefined,
            machine,
          }
        : null,
    );
    setSetupVisit(open && family ? { request, ids: new Set(ready.map(({ id }) => id)), connected: false } : null);
  }
  const currentVisit = setupVisit?.request === request ? setupVisit : null;
  if (
    currentVisit &&
    !currentVisit.connected &&
    available &&
    family &&
    ((family === "claude" && claudeConnected && !recoverySession) ||
      ready.some((c) => servesFamily(c, family) && !currentVisit.ids.has(c.id)))
  ) {
    setSetupVisit({ ...currentVisit, connected: true });
  }
  const ids = routeRows.map(({ id }) => id);
  const order = (next: string[]) => {
    if (locked || next.every((id, index) => id === ids[index])) return;
    const reordered = next.values();
    const visible = new Set(ids);
    const ordered = connections
      .filter(({ kind }) => kind !== "native-login")
      .map((c) => (visible.has(c.id) ? (reordered.next().value ?? c.id) : c.id));
    void rowRun({ action: "order", ids: ordered });
  };
  const setup = selection && "id" in selection ? selection : undefined;
  const rowAction = selection && "kind" in selection ? selection : undefined;
  const visitMachine = setup?.machine ?? machine;
  const visitRecovery = setup && setup.machine === machine && !setup.target ? recoverySession : undefined;
  const visitLogin =
    (claudeLogin?.recoverySession ?? undefined) === visitRecovery &&
    (!visitMachine || claudeLogin?.machine === visitMachine)
      ? claudeLogin
      : undefined;
  const claudeScope = {
    ...(visitMachine ? { machine: visitMachine } : {}),
    ...(visitRecovery ? { recoverySession: visitRecovery } : {}),
  };
  const existingClaude =
    setup?.id === requestedId && family === "claude" && claudeConnected && !recoverySession && !setup?.target;
  const active = setup && !existingClaude ? providerById(setup.id) : undefined;
  const awaitingSignIn =
    active?.id === devicePreset
      ? devicePending || locked
      : (active?.id === "claude" || active?.id === "claude-login") && (claudePending || locked);
  const activeRow = setup?.target
    ? displayed.find((c) => c.id === setup.target)
    : displayed.find((c) => c.id === setup?.id);
  const pick = (next: SetupSelection | RowAction, trigger?: HTMLElement | null) => {
    if ("id" in next && !next.edit) {
      const provider = providerById(next.id);
      if (provider && providerDisabledReason(provider, models?.claudeCodeAvailable, cloud, models?.claudeLogin?.error))
        return;
    }
    if (formError) clearError();
    setFormError(false);
    setPickerOpen(false);
    const rowMachine = "id" in next && next.target === "claude-cloud-login" ? claudeLogin?.machine : undefined;
    setSelection({
      ...next,
      ...(rowMachine ? { machine: rowMachine } : {}),
      returnTo: trigger ?? selection?.returnTo,
    });
  };
  const close = () => {
    if (!selection) return;
    const trigger = selection.returnTo;
    const removingTrigger =
      rowAction?.kind === "disconnect" &&
      trigger?.dataset.menu === `connection-${rowAction.connection.id}` &&
      !store.getSnapshot().models?.personal.connections.some((c) => c.id === rowAction.connection.id);
    returnFocus.current = trigger?.isConnected && !removingTrigger ? trigger : addButton.current;
    setSelection((current) => (current === selection ? null : current));
    if (formError) clearError();
  };
  const dismiss = () => {
    close();
    if (startingDevice.current || (setup?.id === devicePreset && (device === "waiting" || device === "starting"))) {
      void rowRun({ action: "cancelChatGPTDevice" });
    } else if ((setup?.id === "claude" || setup?.id === "claude-login") && visitLogin && (busy || claudePending)) {
      void rowRun({ action: "cancelClaudeLogin", cloud, ...claudeScope });
    }
  };
  const rowRun: Run = (gesture) => {
    setFormError(false);
    if (gesture.action === "signOutClaude" && cloud && claudeLogin?.machine) {
      return run({ ...gesture, machine: claudeLogin.machine });
    }
    return run(gesture);
  };
  const panelRun: Run = (gesture, onVerificationFailure) => {
    setFormError(true);
    if (gesture.action === "finishClaudeLogin") return run({ ...gesture, ...claudeScope });
    if (gesture.action === "connectClaude") {
      return run({
        ...gesture,
        ...claudeScope,
        ...(environment ? { environment } : {}),
        ...(machineName ? { machineName } : {}),
      });
    }
    if (gesture.action !== "connectChatGPTDevice") return run(gesture, onVerificationFailure);
    startingDevice.current = true;
    return run(gesture).finally(() => {
      startingDevice.current = false;
    });
  };

  const unsupported =
    cloud &&
    (!requested || !canAddProvider(requested, true)) &&
    (!family || !cloudRows.some((connection) => servesFamily(connection, family)))
      ? (family ?? requested?.id)
      : undefined;
  const unsupportedBrand = unsupported && !requested ? agentBrandSpec(unsupported) : undefined;
  return (
    <div className="models" data-card={cloud ? "cloudModels" : "models"} aria-busy={locked || loading}>
      <section className="group" data-models-section="personal" tabIndex={reveal ? -1 : undefined} ref={section}>
        <GroupHeader
          title={t(cloud ? "settingsWindow.cloud.models.title" : "settingsWindow.models.personal.title")}
          help={t(cloud ? "settingsWindow.cloud.models.help" : "settingsWindow.models.personal.help")}
        />
        <div className="rows models-rows models-connections">
          {loading && <ConnectionsSkeleton />}
          {!loading && !available && (
            <SettingsErrorRow
              message={t("settingsWindow.models.personal.unavailable")}
              retry={() => void store.refreshModels()}
            />
          )}
          {error && !formError && <SettingsErrorRow message={error} />}
          {available && unsupported && (
            <div className="row" data-cloud-coming-soon="">
              <ModelRow
                mark={requested?.mark ?? { agent: unsupported }}
                label={requested ? providerName(requested) : (unsupportedBrand?.name ?? unsupported)}
                detail={t("settingsWindow.cloud.status.comingSoon")}
              />
            </div>
          )}
          {available && cloud && !unsupported && displayed.length === 0 && cloudTeamKeys.length === 0 && (
            <div className="row">
              <p className="row-help">{t("settingsWindow.cloud.models.empty")}</p>
            </div>
          )}
          {available &&
            displayed.map((connection, index) => {
              const key = menuKey(connection);
              const { credentialInstance: instance, keyRevision } = connection;
              return (
                <ModelConnectionRow
                  key={key}
                  connection={connection}
                  index={ids.indexOf(connection.id) >= 0 ? ids.indexOf(connection.id) : index}
                  count={ids.length}
                  tools={models.connectionTools === true}
                  cloud={cloud}
                  busy={locked}
                  now={now}
                  cloudRunnerStatus={cloud ? cloudRunnerStatus(connection) : undefined}
                  focusRequest={
                    (!cloud && focus === connection.id) || (openMenuKey === key && cloudOff?.id === connection.id)
                      ? request
                      : undefined
                  }
                  menuOpen={openMenuKey === key}
                  onMenuOpenChange={(open) => {
                    setOpenMenuKey((current) => (open ? key : current === key ? null : current));
                  }}
                  run={rowRun}
                  connecting={activeRow === connection && (awaitingSignIn || (!!setup?.edit && locked))}
                  onMove={(to) => order(moveId(ids, connection.id, to))}
                  onSetup={pick}
                  onAction={pick}
                  onCloudChange={
                    cloud && instance && keyRevision && canToggleCloud(connection)
                      ? () =>
                          void rowRun({
                            action: "setCloud",
                            id: connection.id,
                            instance,
                            keyRevision,
                            on: !connection.servesCloud,
                          })
                      : undefined
                  }
                />
              );
            })}
          {available &&
            cloudTeamKeys.map(({ agent }) => (
              <div className="row accounts-row" key={agent}>
                <ModelRow
                  mark={{ agent }}
                  label={sharedModelKeyName(agent)}
                  detail={t("settingsWindow.models.org.keySet")}
                />
              </div>
            ))}
          {available && (
            <ModelProviderPicker
              cloud={cloud}
              claudeCodeAvailable={models?.claudeCodeAvailable}
              claudeError={models?.claudeLogin?.error}
              open={pickerOpen}
              setOpen={setPickerOpen}
              trigger={addButton}
              disabled={locked}
              handingOff={!!active}
              onPick={(id) => pick({ id }, addButton.current)}
            />
          )}
        </div>
        {currentVisit?.connected && (
          <output className="row-help" data-cloud-connected="">
            {fromSend ? t("settingsWindow.models.setup.starting") : t("settingsWindow.models.setup.connected")}
          </output>
        )}
      </section>
      <ModelConnectionDialog
        visit={request}
        cloud={cloud}
        recoverClaude={!!visitRecovery}
        claudeAttemptBlocked={(cloud && models?.cloudClaudeApprovalBusy === true) || (claudePending && !visitLogin)}
        useSettingsClaudeLogin={setup?.useSettingsClaudeLogin}
        provider={available ? active : undefined}
        models={models && cloud ? { ...models, cloudClaudeLogin: visitLogin } : (models ?? undefined)}
        busy={locked}
        setSaving={setSaving}
        error={formError ? error : null}
        target={setup?.target}
        edit={setup?.edit}
        onKeyReplaced={setup?.onKeyReplaced}
        rowAction={rowAction}
        run={panelRun}
        returnFocus={returnFocus}
        onClose={close}
        onDismiss={dismiss}
      />
      {!cloud && (
        <>
          <section className="group" data-models-section="policy">
            <GroupHeader title={t("settingsWindow.models.catalog.policy")} />
            <div className="rows models-rows">
              <div className="row" data-models-row="spread">
                <div className="row-main">
                  <div className="row-label" id={spreadId}>
                    <div className="row-title">{t("settingsWindow.models.spread.title")}</div>
                    <div className="row-help">{t("settingsWindow.models.spread.help")}</div>
                  </div>
                  <div className="row-control">
                    <Switch
                      checked={models?.personal.spread ?? false}
                      disabled={locked || !available}
                      labelId={spreadId}
                      onToggle={(on) => void rowRun({ action: "spread", on })}
                    />
                  </div>
                </div>
              </div>
            </div>
          </section>
          {models && (
            <OrganizationSection key={models.organization.team?.id} models={models} busy={locked} run={rowRun} />
          )}
          {models?.organization.team && models.members?.canEdit && (
            <MembersSection members={models.members} busy={locked} run={rowRun} />
          )}
        </>
      )}
    </div>
  );
}

function ConnectionsSkeleton() {
  return (
    <div data-models-connections-loading="">
      <output className="visually-hidden">{t("settingsWindow.models.loading")}</output>
      {skeletonRows.map((row) => (
        <div className="row accounts-row" key={row} aria-hidden="true">
          <div className="row-main">
            <Skeleton className="models-skeleton-mark" />
            <div className="row-label">
              <Skeleton className="cloud-skeleton-title" shape="line" />
              <Skeleton className="cloud-skeleton-detail" shape="line" />
            </div>
            <Skeleton className="cloud-skeleton-control" />
          </div>
        </div>
      ))}
    </div>
  );
}
