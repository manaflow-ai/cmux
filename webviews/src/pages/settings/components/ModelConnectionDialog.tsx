import { useCallback, useRef, useState, type RefObject } from "react";
import { Input } from "../../../ui/Input";
import { Button } from "../../../ui/Button";
import { Dialog, DialogDescription, DialogTitle } from "../../../ui/Dialog";
import { keyedIconProps } from "../../../ui/DialogButton";
import { focusRoute } from "../../../ui/focusRoute";
import { DeviceSignInCard } from "../../shared/signIn/DeviceSignInCard";
import { userMessage } from "../../shared/userMessage";
import { useStore } from "../context";
import { Icon } from "../icons";
import { SETTINGS_SENTENCES, type ModelConnection, type ModelsState } from "../ops";
import {
  isDeviceSignIn,
  providerDialogTitle,
  regionForUrl,
  providerName,
  type CatalogProvider,
  type LocalSignIn,
  ENDPOINT_MARK,
} from "../providerCatalog";
import { t } from "../strings";
import { ChatGPTDeviceForm } from "./ChatGPTDevicePanel";
import { ClaudeLoginForm } from "./ClaudeLoginForm";
import { ConnectionError, ConnectionFooter, ConnectionRegion, SignInWaiting } from "./ModelConnectionFields";
import { ModelEndpointForm } from "./ModelEndpointForm";
import { ModelKeyForm } from "./ModelKeyForm";
import type { RowAction } from "./ModelConnectionRow";
import { ModelProviderMark } from "./ModelProviderMark";
import { ChiefHost } from "../../home-channels/chiefEditing";
import { markOf, modelEndpointBackend, type Run } from "./modelConnections";
import { useSettingsSignIn, terminalSignIn } from "./useSettingsSignIn";

export function ModelConnectionDialog({
  visit,
  cloud,
  provider,
  models,
  busy,
  error,
  run,
  setSaving,
  onClose,
  onDismiss,
  target,
  edit,
  onKeyReplaced,
  rowAction,
  returnFocus,
}: {
  visit: string;
  cloud: boolean;
  provider?: CatalogProvider;
  models?: ModelsState;
  busy: boolean;
  error: string | null;
  run: Run;
  setSaving(saving: boolean): void;
  onClose(): void;
  onDismiss(): void;
  target?: string;
  edit?: ModelConnection;
  onKeyReplaced?(): void;
  rowAction?: RowAction;
  returnFocus: RefObject<HTMLElement | null>;
}) {
  const store = useStore();
  const accountSignIn = useSettingsSignIn(() => void store.refreshModels());
  const heading = useRef<HTMLDivElement>(null);
  const focusHeading = useCallback((node: HTMLDivElement | null) => {
    heading.current = node;
    focusRoute(node, "system", "Focus the current model connection dialog heading", { preventScroll: true });
  }, []);
  const connection = rowAction?.connection;
  const directClaude = provider?.kind === "claude-login" || (provider?.id === "claude-login" && !target);
  const standaloneChatGPT = models?.personal.connections.some(
    (row) => row.id === target && row.kind === "chatgpt-plan",
  );
  const accountFamily =
    !cloud && accountSignIn.inPlace
      ? directClaude
        ? "claude"
        : (provider?.id === "chatgpt" && !standaloneChatGPT) || provider?.id === "codex-login"
          ? "codex"
          : undefined
      : undefined;
  const dismiss = () => {
    if (accountFamily) accountSignIn.card.onCancel?.();
    onDismiss();
  };
  const title = rowAction
    ? t(
        rowAction.kind === "rename" ? "settingsWindow.models.renameTitle" : "settingsWindow.models.disconnectTitle",
        rowAction.connection.label,
      )
    : provider
      ? edit
        ? t("settingsWindow.models.editTitle", edit.kind === "endpoint" ? edit.label : providerName(provider))
        : directClaude
          ? t(cloud ? "settingsWindow.models.claude.cloudTitle" : "settingsWindow.models.claude.title")
          : providerDialogTitle(provider)
      : "";
  const revokeCopilot = rowAction?.kind === "disconnect" && connection?.kind === "copilot-plan";
  const description =
    rowAction?.kind === "disconnect"
      ? ((revokeCopilot ? undefined : rowAction.description) ?? t("settingsWindow.models.removeConfirm"))
      : undefined;
  const mark =
    provider?.mark ??
    (connection?.kind === "endpoint" ? ENDPOINT_MARK : connection ? { agent: markOf(connection) } : undefined);
  return (
    <Dialog
      open={!!(provider || rowAction)}
      disablePointerDismissal={rowAction?.kind === "disconnect"}
      onOpenChange={(open) => {
        if (!open) dismiss();
      }}
      className="models-dialog ui-glass ui-glass-floats"
      backdropClassName="models-dialog-backdrop"
      initialFocus={heading}
      finalFocus={returnFocus}
      onKeyDown={(event) => {
        if (
          event.key !== "Enter" ||
          event.nativeEvent.isComposing ||
          event.defaultPrevented ||
          event.metaKey ||
          event.altKey ||
          event.ctrlKey ||
          event.shiftKey ||
          (event.target !== heading.current && event.target !== event.currentTarget)
        )
          return;
        const submit = event.currentTarget.querySelector<HTMLButtonElement>('button[type="submit"]:enabled');
        if (submit?.form) {
          event.preventDefault();
          submit.form.requestSubmit(submit);
        }
      }}
    >
      {(provider || rowAction) && models && (
        <div
          key={JSON.stringify([visit, provider?.id, target, edit?.id, rowAction?.kind, connection?.id])}
          className="models-dialog-content"
          data-models-dialog={provider?.id ?? rowAction?.kind}
        >
          <div className="models-dialog-heading" ref={focusHeading} tabIndex={-1}>
            {mark && <ModelProviderMark mark={mark} large />}
            <DialogTitle>{title}</DialogTitle>
            {description && (
              <DialogDescription>
                {description}
                {revokeCopilot && (
                  <>
                    {" "}
                    <a
                      className="channel-link"
                      href="https://github.com/settings/applications"
                      target="_blank"
                      rel="noreferrer"
                    >
                      {t("settingsWindow.models.copilot.revoke")}
                    </a>
                  </>
                )}
              </DialogDescription>
            )}
            {provider && (
              <DialogDescription>
                {t(
                  directClaude
                    ? cloud
                      ? "settingsWindow.models.claude.cloudBody"
                      : "settingsWindow.models.dialog.claude.description"
                    : provider.dialog.description,
                )}
              </DialogDescription>
            )}
          </div>
          <Button
            variant="ghost"
            size="sm"
            icon
            className="models-dialog-close"
            {...keyedIconProps(t("settingsWindow.studio.close"), "escape")}
            onClick={dismiss}
          >
            <Icon name="xmark" />
          </Button>
          {rowAction && (
            <ModelRowActionForm
              action={rowAction}
              busy={busy}
              error={error}
              setSaving={setSaving}
              run={run}
              onClose={onClose}
            />
          )}
          {accountFamily &&
            (accountSignIn.running ? (
              <DeviceSignInCard
                family={accountFamily}
                view={accountSignIn.running.view}
                {...accountSignIn.card}
                onDone={() => {
                  accountSignIn.card.onDone?.();
                  onClose();
                }}
                onCancel={dismiss}
              />
            ) : (
              <form
                className="models-form"
                onSubmit={(event) => {
                  event.preventDefault();
                  accountSignIn.begin(accountFamily, target ?? null, () => {
                    void store.runHarnesses(terminalSignIn(accountFamily, target ?? null));
                  });
                }}
              >
                <ConnectionFooter busy={busy} onClose={dismiss} />
              </form>
            ))}
          {!accountFamily && directClaude && (
            <ClaudeLoginForm
              models={models}
              cloud={cloud}
              busy={busy}
              run={run}
              onClose={onClose}
              onCancel={onDismiss}
              replace={target}
              error={error}
            />
          )}
          {provider && (provider.kind === "api-key" || provider.kind === "openai-endpoint") && (
            <ProviderConnectForm
              provider={provider}
              models={models}
              cloud={cloud}
              busy={busy}
              edit={edit}
              target={target}
              setSaving={setSaving}
              onKeyReplaced={onKeyReplaced}
              error={error}
              run={run}
              onClose={onClose}
              onDismiss={onDismiss}
            />
          )}
          {!accountFamily &&
            provider?.kind === "subscription" &&
            !directClaude &&
            (isDeviceSignIn(provider.signIn) ? (
              <ChatGPTDeviceForm
                signIn={provider.signIn}
                models={models}
                busy={busy}
                run={run}
                onClose={onClose}
                onCancel={onDismiss}
                target={target}
                error={error}
              />
            ) : (
              <LocalSignInForm
                signIn={provider.signIn}
                target={target}
                busy={busy}
                error={error}
                setSaving={setSaving}
                onClose={onClose}
                onCancel={onDismiss}
              />
            ))}
        </div>
      )}
    </Dialog>
  );
}

function ProviderConnectForm({
  provider,
  models,
  cloud,
  busy,
  edit,
  target,
  setSaving,
  onKeyReplaced,
  error,
  run,
  onClose,
  onDismiss,
}: {
  provider: Extract<CatalogProvider, { kind: "api-key" | "openai-endpoint" }>;
  models: ModelsState;
  cloud: boolean;
  busy: boolean;
  edit?: ModelConnection;
  target?: string;
  setSaving(saving: boolean): void;
  onKeyReplaced?(): void;
  error: string | null;
  run: Run;
  onClose(): void;
  onDismiss(): void;
}) {
  const signIn = provider.dialog.method === "device" ? "kimi" : null;
  // An existing key connection of a sign-in provider (an older Kimi Code key) edits as a key.
  const keyMode = !!edit || !signIn;
  const pending =
    models.deviceProvider === signIn &&
    (models.chatgptDevice?.phase === "waiting" ||
      models.chatgptDevice?.phase === "starting" ||
      models.chatgptDevice?.phase === "cancelling");
  const [region, setRegion] = useState(
    (edit?.endpoint && regionForUrl(provider, edit.endpoint.baseUrl))?.id ??
      (models.deviceProvider === signIn ? models.deviceRegion : undefined) ??
      provider.regions?.[0]?.id ??
      "",
  );
  const canCheck = models.connectionTools === true;
  if (!keyMode && signIn) {
    return (
      <ChatGPTDeviceForm
        models={models}
        signIn={signIn}
        region={target ? undefined : region}
        busy={busy}
        run={run}
        onClose={onClose}
        onCancel={onDismiss}
        target={target}
        error={error}
      >
        {!target && (
          <ConnectionRegion provider={provider} value={region} onChange={setRegion} disabled={busy || pending} />
        )}
      </ChatGPTDeviceForm>
    );
  }
  return provider.kind === "api-key" ? (
    <ModelKeyForm
      provider={provider}
      canCheck={canCheck}
      cloud={cloud}
      busy={busy}
      edit={edit}
      onKeyReplaced={onKeyReplaced}
      error={error}
      run={run}
      onClose={onClose}
      onCancel={onDismiss}
    />
  ) : (
    <ModelEndpointForm
      provider={provider}
      saving={busy}
      cloud={cloud}
      edit={edit}
      region={region}
      onRegionChange={setRegion}
      setSaving={setSaving}
      onDone={onClose}
      onCancel={onDismiss}
    />
  );
}

function LocalSignInForm({
  signIn,
  target,
  busy,
  error,
  setSaving,
  onClose,
  onCancel,
}: {
  signIn: LocalSignIn;
  target?: string;
  busy: boolean;
  error: string | null;
  setSaving(saving: boolean): void;
  onClose(): void;
  onCancel(): void;
}) {
  const store = useStore();
  const [failure, setFailure] = useState<string | null>(null);
  const [waiting, setWaiting] = useState(false);
  const starting = useRef(false);
  const start = async () => {
    if (busy || starting.current) return;
    starting.current = true;
    setSaving(true);
    setWaiting(true);
    setFailure(null);
    try {
      if (target) {
        const reply = await store.runHarnesses({ action: "accountSignIn", account: target });
        if (!reply.ok) setFailure(userMessage(reply.error, SETTINGS_SENTENCES));
        else onClose();
      } else {
        const refusal = await store.runAccounts({ action: "reauth", provider: signIn });
        if (refusal) setFailure(refusal);
        else onClose();
      }
    } catch (error) {
      setFailure(userMessage(error, SETTINGS_SENTENCES));
    } finally {
      starting.current = false;
      setWaiting(false);
      setSaving(false);
    }
  };
  return (
    <form
      className="models-form"
      onSubmit={(event) => {
        event.preventDefault();
        void start();
      }}
    >
      {waiting && <SignInWaiting>{t("settingsWindow.models.waiting.browser")}</SignInWaiting>}
      {(failure || error) && <ConnectionError>{failure ?? error}</ConnectionError>}
      <ConnectionFooter
        onClose={onCancel}
        busy={busy}
        failed={!!(failure || error)}
        connectAction="localSignIn"
        loading={waiting}
      />
    </form>
  );
}

function ModelRowActionForm({
  action,
  busy,
  error,
  setSaving,
  run,
  onClose,
}: {
  action: RowAction;
  busy: boolean;
  error: string | null;
  setSaving(saving: boolean): void;
  run: Run;
  onClose(): void;
}) {
  const store = useStore();
  const { connection } = action;
  const [draft, setDraft] = useState(connection.label);
  const [failure, setFailure] = useState<string | null>(null);
  const pending = useRef(false);
  const rename = action.kind === "rename";
  const name = draft.trim();
  const endpoint = connection.endpoint;
  const valid =
    !rename || (!!name && name !== connection.label && (!endpoint || new TextEncoder().encode(name).length <= 100));
  const submit = async () => {
    if (!valid || busy || pending.current) return;
    if (!endpoint) {
      if (await run(rename ? { action: "rename", id: connection.id, name } : { action: "remove", id: connection.id }))
        onClose();
      return;
    }
    pending.current = true;
    setSaving(true);
    setFailure(null);
    try {
      if (rename) {
        await new ChiefHost(store.chiefCalls).addBackend(
          modelEndpointBackend(
            { ...endpoint, name, models: endpoint.models.join(","), apiKey: "" },
            { id: connection.id, own: true, typedKey: connection.signedIn },
            { revision: endpoint.revision },
          ),
        );
      } else {
        const reply = await store.runAgents({ action: "remove", id: connection.id });
        if (!reply.ok) {
          setFailure(userMessage(reply.error, SETTINGS_SENTENCES));
          return;
        }
      }
      await store.refreshModels();
      onClose();
    } catch (reason) {
      setFailure(userMessage(reason, SETTINGS_SENTENCES));
    } finally {
      pending.current = false;
      setSaving(false);
    }
  };
  return (
    <form
      className="models-form"
      data-connection-remove={rename ? undefined : ""}
      onSubmit={(event) => {
        event.preventDefault();
        void submit();
      }}
    >
      {rename && (
        <label className="models-field">
          <span>{t("settingsPage.agents.name")}</span>
          <Input
            className="field"
            value={draft}
            disabled={busy}
            maxLength={128}
            onChange={(event) => setDraft(event.target.value)}
          />
        </label>
      )}
      {(failure || error) && <ConnectionError>{failure ?? error}</ConnectionError>}
      <ConnectionFooter
        onClose={onClose}
        busy={busy}
        disabled={!valid}
        danger={!rename}
        label={t(rename ? "settingsWindow.density.save" : "settingsWindow.models.disconnect")}
        connectAction={rename ? "rename" : "confirmRemove"}
      />
    </form>
  );
}
