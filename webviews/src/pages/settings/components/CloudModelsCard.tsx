// Settings > Cloud > Models for Cloud (cmux-tui/docs/model-connections.md, Revision 2): whether a Cloud
// chat on Claude, on ChatGPT (Codex) or on an API key has a connection that serves it, one row each, so a
// Mac login that shows healthy in Settings > Models but cannot reach Cloud (servesCloud false) no longer
// reads as set up. A row is Connected for Cloud by the rule a Cloud start uses (CloudSetup.swift
// `choice`): an enabled, signed-in personal connection that serves Cloud and the family, else the team's
// shared key for it. Set Up opens Settings > Models' own Add a Connection steps (`claudeSetupToken` and
// `addClaudeToken`, `addKey`) and Continue with ChatGPT runs `connectChatGPT`; this card adds no second
// way in. `?focus=cloud.claude`, `cloud.chatgpt` or `cloud.apiKey` (the chat's Set up Cloud card,
// cmux://settings/cloud/...) opens the page on that row. A Claude or ChatGPT row on a connection of the
// person's own offers Reconnect (a ChatGPT sign-in again, `connectChatGPT`) or Edit (a new Claude token or key
// that replaces it) and Sign Out (`remove`; a built-in Mac login can't be removed, so it is turned off).
import { useId, useState } from "react";
import { AgentMark } from "../../../agent-session/shared/AgentMark";
import { Button } from "../../../ui/Button";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../../ui/Menu";
import { useSettingsRouter, useSettingsState } from "../context";
import { Icon } from "../icons";
import { revealRow } from "../keyboard";
import type { ModelConnection, ModelProvider, ModelsRun, ModelsState } from "../ops";
import { sectionHref } from "../router";
import { t } from "../strings";
import { AddConnectionSheet, ChatGPTStatus, PROVIDERS, useModelsRun, type Run, type SheetStart } from "./ModelsCard";

/** The rows, in order; each is the focus that opens the page on it (`cloud.<row>`). */
export const CLOUD_ROWS = ["claude", "chatgpt", "apiKey"] as const;
export type CloudRow = (typeof CLOUD_ROWS)[number];

/** Product names, shown as they are in every language. */
const ROW_NAMES: Record<Exclude<CloudRow, "apiKey">, string> = { claude: "Claude", chatgpt: "ChatGPT" };
const AGENT_NAMES: Record<"claude" | "codex", string> = { claude: "Claude", codex: "Codex" };
/** The API-key providers whose keys reach Cloud chats (acpmux connections.rs `serves_cloud`). */
const CLOUD_KEY_PROVIDERS: ModelProvider[] = ["anthropic", "openai"];

/** One row's state: `ready` (a Cloud chat starts on `via`), `off` (a connection that would serve is
 * turned off or signed out), `missing` (nothing serves it). `macOnly` is a connection of the row's kind
 * that works on this Mac only, named when the row is not ready. */
export type CloudReadiness = {
  state: "ready" | "off" | "missing";
  via: string | null;
  macOnly: ModelConnection | null;
  /** The person's own connection the row reads (`via`'s); null when nothing of theirs serves or the team's key does. */
  connection: ModelConnection | null;
};

const works = (connection: ModelConnection) => connection.enabled && connection.signedIn;

/** A row's readiness from the models read, by the rule a Cloud start uses. */
export function cloudReadiness(models: ModelsState, row: CloudRow): CloudReadiness {
  const connections = models.personal.connections;
  if (row === "apiKey") {
    const keys = connections.filter((c) => c.kind === "api-key");
    const serving = keys.filter((c) => c.servesCloud);
    const ready = serving.find(works);
    const macOnly = keys.find((c) => !c.servesCloud) ?? null;
    if (ready) return { state: "ready", via: ready.label, macOnly, connection: ready };
    const first = serving[0] ?? null;
    return { state: first ? "off" : "missing", via: first?.label ?? null, macOnly, connection: first };
  }
  const family = row === "claude" ? "claude" : "codex";
  const serving = connections.filter((c) => c.servesCloud && c.families.includes(family));
  const macOnly = connections.find((c) => !c.servesCloud && c.kind === `${family}-login`) ?? null;
  const ready = serving.find(works);
  if (ready) return { state: "ready", via: ready.label, macOnly, connection: ready };
  const team = models.organization.team && models.organization.keys.some((key) => key.agent === family && key.set);
  // The team's shared key serves the family after the person's own (Settings > Models' Organization).
  if (team)
    return { state: "ready", via: t("settingsWindow.models.org.key", AGENT_NAMES[family]), macOnly, connection: null };
  const first = serving[0] ?? null;
  return { state: first ? "off" : "missing", via: first?.label ?? null, macOnly, connection: first };
}

/** A Cloud row's Reconnect or Edit for its own connection, or null: a ChatGPT sign-in (on Codex's client)
 * signs in again in place, a Codex CLI login is replaced by Sign in with ChatGPT, and a Claude token or an
 * API key is replaced by a new one pasted in Add a Connection's own steps. */
export type CloudRedo =
  | { label: "reconnect"; gesture: ModelsRun }
  | { label: "edit"; start: SheetStart; replaces: string };

export function cloudRedo(connection: ModelConnection | null): CloudRedo | null {
  if (!connection) return null;
  switch (connection.kind) {
    case "chatgpt-plan":
      return { label: "reconnect", gesture: { action: "connectChatGPT", id: connection.id } };
    case "codex-login":
      return { label: "reconnect", gesture: { action: "connectChatGPT" } };
    case "claude-token":
      return { label: "edit", start: "claude", replaces: connection.id };
    case "api-key":
      return { label: "edit", start: connection.provider, replaces: connection.id };
    default:
      return null;
  }
}

/** Whether Sign Out removes the connection; a built-in Mac login (Claude Code's or the Codex CLI's) is turned off. */
const removable = (connection: ModelConnection) =>
  connection.kind !== "codex-login" && connection.kind !== "claude-login";

export function CloudModelsCard({ focus }: { focus: string | null }) {
  const models = useSettingsState().models;
  const { busy, error, run } = useModelsRun();
  const [sheet, setSheet] = useState<{ start: SheetStart; replaces: string | null } | null>(null);
  if (!models) return null;
  const available = models.personal.available;
  return (
    <section className="group" data-card="cloudModels" aria-busy={busy}>
      <h3 className="group-title">{t("settingsWindow.cloud.models.title")}</h3>
      <p className="row-help">{t("settingsWindow.cloud.models.help")}</p>
      {error && (
        <p className="row-error" role="alert" data-models-error="">
          {error}
        </p>
      )}
      <div className="rows">
        {!available ? (
          <div className="row" data-empty="">
            <span className="row-help">{t("settingsWindow.models.personal.unavailable")}</span>
          </div>
        ) : (
          CLOUD_ROWS.map((row) => (
            <CloudModelRow
              key={row}
              row={row}
              models={models}
              focused={focus === `cloud.${row}`}
              busy={busy}
              run={run}
              onSetUp={(start, replaces = null) => setSheet({ start, replaces })}
            />
          ))
        )}
      </div>
      {sheet && (
        <AddConnectionSheet
          models={models}
          busy={busy}
          run={run}
          start={sheet.start}
          replaces={sheet.replaces}
          onClose={() => setSheet(null)}
        />
      )}
    </section>
  );
}

function CloudModelRow({
  row,
  models,
  focused,
  busy,
  run,
  onSetUp,
}: {
  row: CloudRow;
  models: ModelsState;
  focused: boolean;
  busy: boolean;
  run: Run;
  onSetUp(start: SheetStart, replaces?: string | null): void;
}) {
  const router = useSettingsRouter();
  const nameId = useId();
  // The connection whose Sign Out is being confirmed: a confirm never carries over to another connection.
  const [confirmingId, setConfirmingId] = useState<string | null>(null);
  const { state, via, macOnly, connection } = cloudReadiness(models, row);
  // Reconnect / Edit and Sign Out: the Claude and ChatGPT rows, on a connection of the person's own.
  const own = row === "apiKey" ? null : connection;
  const redo = cloudRedo(own);
  const confirming = own !== null && confirmingId === own.id;
  const title = row === "apiKey" ? t("settingsWindow.harnesses.accounts.apiKey") : ROW_NAMES[row];
  const status =
    state === "ready"
      ? t("settingsWindow.cloud.status.ready")
      : state === "off"
        ? t("settingsWindow.cloud.status.off")
        : t("settingsWindow.cloud.status.missing");
  // A Mac-only login of the row's kind, said plainly with what Cloud needs instead (two short lines).
  const note: string[] =
    state === "ready" || !macOnly
      ? []
      : row === "claude"
        ? [t("settingsWindow.cloud.claude.macOnly"), t("settingsWindow.cloud.claude.needs")]
        : row === "chatgpt"
          ? [t("settingsWindow.cloud.chatgpt.macOnly"), t("settingsWindow.cloud.chatgpt.needs")]
          : [t("settingsWindow.cloud.apiKey.macOnly")];
  const pending = row === "chatgpt" && (models.chatgpt.attempt !== null || models.chatgpt.error !== null);
  // Sign Out: never while a ChatGPT sign-in is pending, and not on a built-in Mac login already turned off.
  const canSignOut = own !== null && !pending && (removable(own) || own.enabled);
  return (
    <div
      className="row accounts-row"
      tabIndex={-1}
      data-cloud-row={row}
      data-cloud-status={state}
      ref={focused ? revealRow : undefined}
    >
      <div className="row-main">
        <span className="accounts-mark" aria-hidden="true">
          {row === "apiKey" ? (
            <Icon name="lock" />
          ) : (
            <AgentMark agent={row === "claude" ? "claude" : "openai"} size={16} />
          )}
        </span>
        <div className="row-label">
          <div className="row-title" id={nameId}>
            {title}
          </div>
          {row === "apiKey" && <div className="row-help">{t("settingsWindow.cloud.apiKey.help")}</div>}
          <div className="row-help" data-cloud-status-text="">
            {status}
          </div>
          {via && (
            // The connection's own name (a value, like an address): which one a Cloud chat uses.
            <div className="row-help selectable" data-cloud-via="">
              {via}
            </div>
          )}
          {note.length > 0 && (
            <div data-cloud-mac-only="">
              {note.map((line) => (
                <div key={line} className="row-help">
                  {line}
                </div>
              ))}
            </div>
          )}
        </div>
        <div className="accounts-buttons">
          {state === "off" && (
            <Button
              type="button"
              className="button"
              data-cloud-action="openModels"
              onClick={() => router.history.push(sectionHref("models"))}
            >
              {t("settingsWindow.cloud.openModels")}
            </Button>
          )}
          {redo && !pending && (
            <Button
              type="button"
              className="button"
              data-cloud-action={redo.label}
              disabled={busy}
              onClick={() => (redo.label === "reconnect" ? void run(redo.gesture) : onSetUp(redo.start, redo.replaces))}
            >
              {t(redo.label === "reconnect" ? "settingsWindow.cloud.reconnect" : "settingsWindow.cloud.edit")}
            </Button>
          )}
          {canSignOut && (
            <Button
              type="button"
              className="button"
              data-cloud-action="signOut"
              disabled={busy || confirming}
              onClick={() => setConfirmingId(own?.id ?? null)}
            >
              {t("settingsWindow.cloud.signOut")}
            </Button>
          )}
          {state === "missing" && row === "claude" && (
            <Button
              type="button"
              className="button"
              variant="solid"
              data-cloud-action="setUpClaude"
              disabled={busy}
              onClick={() => onSetUp("claude")}
            >
              {t("settingsWindow.cloud.setUp")}
            </Button>
          )}
          {state === "missing" && row === "chatgpt" && !pending && (
            <Button
              type="button"
              className="button"
              variant="solid"
              data-cloud-action="connectChatGPT"
              disabled={busy}
              onClick={() => void run({ action: "connectChatGPT" })}
            >
              {t("settingsWindow.models.chatgpt.continue")}
            </Button>
          )}
          {state === "missing" && row === "apiKey" && (
            <Menu>
              <MenuButton
                className="button"
                label={t("settingsWindow.cloud.apiKey.add")}
                data-menu="cloud-api-key"
                disabled={busy}
              >
                {t("settingsWindow.cloud.apiKey.add")}
              </MenuButton>
              <MenuPopup align="end">
                {CLOUD_KEY_PROVIDERS.map((provider) => (
                  <MenuItem key={provider} data-value={provider} onSelect={() => onSetUp(provider)}>
                    {PROVIDERS[provider]}
                  </MenuItem>
                ))}
              </MenuPopup>
            </Menu>
          )}
        </div>
      </div>
      {own && confirming && (
        <div className="accounts-body">
          <div className="accounts-form" role="alertdialog" aria-labelledby={nameId} data-cloud-sign-out="">
            <span className="row-help">
              {removable(own)
                ? t("settingsWindow.models.removeConfirm", own.label)
                : t("settingsWindow.cloud.turnOffConfirm", own.label)}
            </span>
            <div className="accounts-buttons">
              <Button
                danger
                type="button"
                className="button danger"
                data-cloud-action="confirmSignOut"
                disabled={busy}
                onClick={() => {
                  setConfirmingId(null);
                  void run(
                    removable(own) ? { action: "remove", id: own.id } : { action: "enable", id: own.id, on: false },
                  );
                }}
              >
                {t("settingsWindow.cloud.signOut")}
              </Button>
              <Button type="button" className="button" onClick={() => setConfirmingId(null)}>
                {t("settingsWindow.cancel")}
              </Button>
            </div>
          </div>
        </div>
      )}
      {row === "chatgpt" && pending && (
        <div className="accounts-body">
          <ChatGPTStatus chatgpt={models.chatgpt} busy={busy} run={run} />
        </div>
      )}
    </div>
  );
}
