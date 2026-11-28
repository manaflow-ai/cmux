import { useId, useLayoutEffect, useRef, type ReactNode } from "react";
import { Spinner } from "../../../agent-session/acpmux/conversation/icons";
import { Button } from "../../../ui/Button";
import { Menu, MenuButton, MenuItem, MenuPopup, MenuSeparator } from "../../../ui/Menu";
import { useSettingsState, useStore } from "../context";
import { Switch } from "../editors/ToggleEditor";
import { DeviceSignInCard } from "../../shared/signIn/DeviceSignInCard";
import { parseAccountRow } from "../../shared/signIn/accountSignIn";
import { useSettingsSignIn } from "./useSettingsSignIn";
import { planName } from "../harnesses";
import { Icon } from "../icons";
import { revealRow } from "../keyboard";
import type { ModelConnection } from "../ops";
import { endpointPresetId, providerById, type CatalogProvider, ENDPOINT_MARK } from "../providerCatalog";
import { useConnectionQuiet } from "../../../ui/lasting";
import { locale, t } from "../strings";
import { ModelAccess, useModelAccess } from "./ModelConnectionFields";
import { ModelProviderMark } from "./ModelProviderMark";
import { isCloudSubscription, markOf, tokenTimeRemaining, type Run, type SetupSelection } from "./modelConnections";

export type RowAction = {
  kind: "rename" | "disconnect" | "replaceClaudeToken";
  connection: ModelConnection;
};

export function ModelConnectionRow({
  connection,
  index,
  count,
  tools,
  cloud,
  busy,
  now,
  cloudRunnerStatus,
  focusRequest,
  menuOpen,
  onMenuOpenChange,
  connecting,
  run,
  onMove,
  onSetup,
  onAction,
  onCloudChange,
}: {
  connection: ModelConnection;
  index: number;
  count: number;
  tools: boolean;
  cloud: boolean;
  busy: boolean;
  now: number;
  cloudRunnerStatus?: "updating" | "offline" | "notReady";
  focusRequest?: string;
  menuOpen: boolean;
  onMenuOpenChange(open: boolean): void;
  connecting: boolean;
  run: Run;
  onMove(to: number): void;
  onSetup(selection: SetupSelection, trigger: HTMLElement): void;
  onAction(action: RowAction, trigger: HTMLElement): void;
  onCloudChange?(): void;
}) {
  const row = useRef<HTMLDivElement>(null);
  const nameId = useId();
  const menu = useRef<HTMLButtonElement>(null);
  useLayoutEffect(() => {
    if (focusRequest) revealRow(row.current);
  }, [focusRequest]);
  const store = useStore();
  const listed = useSettingsState().accounts?.signInAccounts;
  const signIn = useSettingsSignIn(() => void store.refreshModels());
  const access = useModelAccess();
  const action = (next: RowAction) => {
    if (menu.current) onAction(next, menu.current);
  };
  const nativeLogin = connection.kind === "native-login";
  const builtin = connection.kind === "codex-login" || connection.kind === "claude-login";
  const apiKey = connection.kind === "api-key";
  const endpoint = connection.kind === "endpoint";
  const cloudSubscription = isCloudSubscription(connection);
  const otherBuild = connection.signInReason === "keychain_other_build";
  const kimiOtherBuild = otherBuild && connection.kind === "kimi-plan";
  const checking = access.state === "checking";
  const failure = access.result && "failure" in access.result;
  const expires = cloud && connection.expiresAt ? new Date(connection.expiresAt * 1000) : undefined;
  const remaining = tokenTimeRemaining(connection, now);
  const date = expires?.toLocaleDateString(locale(), { dateStyle: "medium" });
  const renewal =
    date && remaining <= 30 * 24 * 60 * 60 * 1000
      ? remaining <= 0
        ? t("settingsWindow.models.cloud.expired")
        : t("settingsWindow.models.cloud.renew", date)
      : undefined;
  const warning = !connection.enabled
    ? undefined
    : (renewal ??
      (kimiOtherBuild
        ? t("settingsWindow.models.kimi.keychainOtherBuild.error")
        : failure
          ? t("settingsWindow.models.status.refused")
          : !connection.signedIn && !endpoint
            ? t(otherBuild ? "settingsWindow.models.keychainOtherBuild" : "settingsWindow.models.status.signInNeeded")
            : undefined));
  const kind = t(
    endpoint
      ? "settingsWindow.models.kind.custom"
      : apiKey
        ? "settingsWindow.models.key.field"
        : "settingsWindow.models.kind.subscription",
  );
  const provider = apiKey ? providerById(connection.provider) : undefined;
  const edit =
    (apiKey && connection.canReplaceKey && !!connection.credentialInstance && provider?.kind === "api-key") ||
    (endpoint && !!connection.endpoint);
  // Legacy Cloud token rows offer migration to the machine login.
  const legacyClaude = cloud && connection.kind === "claude-token";
  const reauthProvider =
    connection.id === "claude-cloud-login" || legacyClaude
      ? "claude"
      : connection.kind === "kimi-plan"
        ? kimiOtherBuild
          ? undefined
          : "kimi-code"
        : cloudSubscription && connection.kind !== "claude-token"
          ? connection.kind.slice(0, -"-plan".length)
          : builtin
            ? connection.kind
            : connection.kind === "subscription"
              ? connection.families[0] === "claude"
                ? "claude-login"
                : "codex-login"
              : undefined;
  const reauthTarget = !builtin || connection.id === "claude-cloud-login" ? connection.id : undefined;
  const reconnect = useRef<HTMLButtonElement>(null);
  const rename =
    tools &&
    !nativeLogin &&
    connection.kind !== "claude-login" &&
    (endpoint ? !!connection.endpoint : connection.kind === "codex-login" || !!connection.credentialInstance);
  const disconnect = cloud
    ? cloudSubscription || (apiKey && connection.servesCloud && !!connection.credentialInstance)
    : !nativeLogin && !builtin && (!endpoint || !!connection.endpoint);
  const enableCloudSubscription = cloud && cloudSubscription && !legacyClaude && !connection.enabled;
  const status =
    !connection.enabled && connection.kind === "claude-token"
      ? t("settingsWindow.models.status.turnedOff")
      : connection.kind === "claude-token"
        ? undefined
        : cloud && !connection.servesCloud && connection.kind !== "claude-login" && !legacyClaude
          ? t(onCloudChange ? "settingsWindow.cloud.status.offForNewChats" : "settingsWindow.cloud.status.notUsed")
          : !connection.enabled
            ? t("settingsWindow.models.status.turnedOff")
            : (warning ??
              (cloudRunnerStatus === "updating"
                ? t("settingsWindow.cloud.status.updating")
                : cloudRunnerStatus === "offline"
                  ? t("settingsWindow.cloud.status.offline")
                  : cloudRunnerStatus === "notReady"
                    ? t("settingsWindow.cloud.status.notReady")
                    : undefined));
  const plan = planName(connection.families[0] ?? "", connection.plan);
  const details = [
    connection.email,
    plan,
    connection.kind !== "claude-token" &&
      connection.signedIn &&
      connection.enabled &&
      date &&
      !renewal &&
      t("settingsWindow.models.cloud.readyUntil", date),
  ]
    .filter(Boolean)
    .join(" · ");
  const emailSuffix = connection.kind === "chatgpt-plan" && connection.email ? ` (${connection.email})` : "";
  const label =
    emailSuffix && connection.label.endsWith(emailSuffix)
      ? connection.label.slice(0, -emailSuffix.length)
      : connection.label;
  const canCheck = tools && connection.canCheckAccess;

  return (
    <div
      className="row models-connection"
      data-connection={connection.id}
      ref={row}
      tabIndex={focusRequest ? -1 : undefined}
    >
      <ModelRow
        mark={endpoint ? ENDPOINT_MARK : { agent: markOf(connection) }}
        label={label}
        nameId={nameId}
        detail={legacyClaude ? undefined : kind}
        account={builtin ? (connection.email ?? undefined) : undefined}
        status={status}
        warning={warning}
        loading={connecting || checking}
        checking={checking}
      >
        {cloud && apiKey && !connection.enabled && (
          <Button
            variant="solid"
            size="sm"
            disabled={busy}
            onClick={() => void run({ action: "enable", id: connection.id, on: true })}
          >
            {t("settingsWindow.cloud.turnOn")}
          </Button>
        )}
        {legacyClaude && reauthProvider && (
          <Button
            variant="solid"
            size="sm"
            ref={reconnect}
            data-connection-action="reconnect"
            disabled={busy}
            onClick={() => {
              if (reconnect.current) onSetup({ id: reauthProvider, target: reauthTarget }, reconnect.current);
            }}
          >
            {t("settingsWindow.models.reconnect")}
          </Button>
        )}
        {(!nativeLogin || details) && (
          <Menu
            open={menuOpen}
            onOpenChange={(open) => {
              if (!open || !busy) onMenuOpenChange(open);
            }}
          >
            <MenuButton
              className="ui-btn models-more"
              variant="ghost"
              size="sm"
              aria-haspopup="menu"
              buttonRef={menu}
              label={t("settingsWindow.models.more", label)}
              data-menu={`connection-${connection.id}`}
              aria-disabled={busy || undefined}
            >
              <Icon name="ellipsis" />
            </MenuButton>
            <MenuPopup align="end" className="models-row-menu">
              {details && <div className="ui-menu-group-label models-menu-details">{details}</div>}
              {legacyClaude && connection.credentialInstance && (
                <MenuItem
                  data-value="replaceClaudeToken"
                  onSelect={() => action({ kind: "replaceClaudeToken", connection })}
                >
                  <Icon name="reset" />
                  {t("settingsWindow.models.org.replace")}
                </MenuItem>
              )}
              {onCloudChange && (
                <MenuItem data-value="setCloud" onSelect={onCloudChange}>
                  <Icon name="cloud" />
                  {t(
                    connection.servesCloud ? "settingsWindow.models.cloud.stopUse" : "settingsWindow.models.cloud.use",
                  )}
                </MenuItem>
              )}
              {edit && (
                <MenuItem
                  data-value="edit"
                  disabled={checking}
                  onSelect={() => {
                    if (menu.current)
                      onSetup(
                        {
                          id: connection.endpoint ? endpointPresetId(connection.endpoint) : connection.provider,
                          target: connection.id,
                          edit: connection,
                          onKeyReplaced: apiKey ? access.clear : undefined,
                        },
                        menu.current,
                      );
                  }}
                >
                  <Icon name="square.and.pencil" />
                  {t("settingsWindow.models.edit")}
                </MenuItem>
              )}
              {reauthProvider && !legacyClaude && (
                <MenuItem
                  data-value="signInAgain"
                  onSelect={() => {
                    if (!cloud && connection.kind === "claude-login") {
                      const fallback = () => {
                        if (menu.current) onSetup({ id: "claude-login", useSettingsClaudeLogin: true }, menu.current);
                      };
                      if (!signIn.inPlace) return fallback();
                      const own = (listed ?? [])
                        .flatMap((raw) => parseAccountRow(raw) ?? [])
                        .find((account) => account.family === "claude" && account.builtin);
                      return signIn.begin("claude", own && !own.signedIn ? own.id : null, fallback);
                    }
                    if (menu.current) onSetup({ id: reauthProvider, target: reauthTarget }, menu.current);
                  }}
                >
                  <Icon name="reset" />
                  {t(otherBuild ? "settingsWindow.models.signInAgain" : "settingsWindow.models.reauthenticate")}
                </MenuItem>
              )}
              {rename && (
                <MenuItem data-value="rename" onSelect={() => action({ kind: "rename", connection })}>
                  <Icon name="textformat" />
                  {t("settingsWindow.menus.rename")}
                </MenuItem>
              )}
              {canCheck && (
                <MenuItem
                  data-value="checkAccess"
                  disabled={checking}
                  onSelect={() => void access.check({ action: "checkAccess", id: connection.id })}
                >
                  <Icon name="checkmark" />
                  {t("settingsWindow.models.access.check")}
                </MenuItem>
              )}
              {access.result && <ModelAccess access={access} />}
              {!cloud && !nativeLogin && (edit || reauthProvider || rename || canCheck) && <MenuSeparator />}
              {!cloud && !nativeLogin && (
                <>
                  <MenuItem data-value="moveUp" disabled={index === 0} onSelect={() => onMove(index - 1)}>
                    <Icon name="chevron" className="models-move-up" />
                    {t("settingsWindow.models.moveUp")}
                  </MenuItem>
                  <MenuItem data-value="moveDown" disabled={index === count - 1} onSelect={() => onMove(index + 1)}>
                    <Icon name="chevron" />
                    {t("settingsWindow.models.moveDown")}
                  </MenuItem>
                </>
              )}
              {enableCloudSubscription && (
                <>
                  <MenuSeparator />
                  <MenuItem
                    data-value="enable"
                    onSelect={() => void run({ action: "enable", id: connection.id, on: true })}
                  >
                    <Icon name="link" />
                    {t("settingsWindow.cloud.turnOn")}
                  </MenuItem>
                </>
              )}
              {connection.kind === "claude-login" && connection.signedIn && (
                <MenuItem data-value="signOutClaude" onSelect={() => void run({ action: "signOutClaude", cloud })}>
                  <Icon name="link.slash" />
                  {t("settingsWindow.models.claude.signOut")}
                </MenuItem>
              )}
              {disconnect && (
                <>
                  <MenuSeparator />
                  <MenuItem
                    className="ui-menu-item-destructive"
                    data-value="remove"
                    onSelect={() => action({ kind: "disconnect", connection })}
                  >
                    <Icon name="link.slash" />
                    {t("settingsWindow.models.disconnect")}
                  </MenuItem>
                </>
              )}
            </MenuPopup>
          </Menu>
        )}
        {((!cloud && !nativeLogin && !endpoint) || legacyClaude) && (
          <Switch
            checked={connection.enabled}
            disabled={busy}
            labelId={nameId}
            onToggle={(on) => void run({ action: "enable", id: connection.id, on })}
          />
        )}
      </ModelRow>
      {signIn.running && (
        <div className="harness-sign-in" data-connection-sign-in={connection.id}>
          <DeviceSignInCard family={signIn.running.family} view={signIn.running.view} {...signIn.card} />
        </div>
      )}
      <div className="visually-hidden" aria-live="polite">
        {access.result &&
          ("failure" in access.result
            ? access.result.failure
            : access.result.models.length === 1
              ? t("settingsWindow.models.access.oneModel")
              : t("settingsWindow.models.access.modelCount", access.result.models.length))}
      </div>
    </div>
  );
}

export function ModelRow({
  mark,
  label,
  nameId,
  detail,
  account,
  status,
  warning,
  loading,
  checking,
  children,
}: {
  mark: CatalogProvider["mark"];
  label: string;
  nameId?: string;
  detail?: string;
  account?: string;
  status?: string;
  warning?: string;
  loading?: boolean;
  checking?: boolean;
  children?: ReactNode;
}) {
  // The spinner shows at once; its "Connecting" words wait out the shared quiet bound.
  const connectingLasting = useConnectionQuiet(!!loading && !checking);
  const iconLabel = loading
    ? checking
      ? t("settingsWindow.models.status.checking")
      : connectingLasting
        ? t("settingsWindow.models.status.connecting")
        : undefined
    : warning;
  return (
    <div className="row-main">
      <ModelProviderMark mark={mark} />
      <div className="row-label">
        <div className="row-title models-connection-name" id={nameId}>
          {label}
        </div>
        {detail && <div className="row-help models-row-detail">{detail}</div>}
        {account && <div className="row-help models-account-email">{account}</div>}
        {status && (
          <div className="row-help models-row-status" data-warning={warning ? "" : undefined}>
            {status}
          </div>
        )}
      </div>
      <div className="row-control">
        <span
          className="models-status-slot"
          data-warning={!loading && warning ? "" : undefined}
          role={iconLabel ? "img" : undefined}
          aria-label={iconLabel}
          title={iconLabel}
        >
          {loading ? <Spinner size={16} loading /> : warning ? <Icon name="warning" /> : null}
        </span>
        {children}
      </div>
    </div>
  );
}
