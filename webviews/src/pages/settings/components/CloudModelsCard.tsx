// Settings > Cloud > Models for Cloud (cmux-tui/docs/model-connections.md, Revision 2): whether a Cloud
// chat on Claude, on ChatGPT (Codex) or on an API key has a connection that serves it, one row each, so a
// Mac login that shows healthy in Settings > Models but cannot reach Cloud (servesCloud false) no longer
// reads as set up. A row is Connected for Cloud by the rule a Cloud start uses (CloudSetup.swift
// `choice`): an enabled, signed-in personal connection that serves Cloud and the family, else the team's
// shared key for it. Set Up opens Settings > Models' own Add a Connection steps (`claudeSetupToken` and
// `addClaudeToken`, `addKey`) and Continue with ChatGPT runs `connectChatGPT`; this card adds no second
// way in. `?focus=cloud.claude`, `cloud.chatgpt` or `cloud.apiKey` (the chat's Set up Cloud card,
// cmux://settings/cloud/...) opens the page on that row.
import { useState } from "react";
import { AgentMark } from "../../../agent-session/shared/AgentMark";
import { Button } from "../../../ui/Button";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../../ui/Menu";
import { useSettingsRouter, useSettingsState } from "../context";
import { Icon } from "../icons";
import { revealRow } from "../keyboard";
import type { ModelConnection, ModelProvider, ModelsState } from "../ops";
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
    if (ready) return { state: "ready", via: ready.label, macOnly };
    return { state: serving.length > 0 ? "off" : "missing", via: serving[0]?.label ?? null, macOnly };
  }
  const family = row === "claude" ? "claude" : "codex";
  const serving = connections.filter((c) => c.servesCloud && c.families.includes(family));
  const macOnly = connections.find((c) => !c.servesCloud && c.kind === `${family}-login`) ?? null;
  const ready = serving.find(works);
  if (ready) return { state: "ready", via: ready.label, macOnly };
  const team = models.organization.team && models.organization.keys.some((key) => key.agent === family && key.set);
  // The team's shared key serves the family after the person's own (Settings > Models' Organization).
  if (team) return { state: "ready", via: t("settingsWindow.models.org.key", AGENT_NAMES[family]), macOnly };
  return { state: serving.length > 0 ? "off" : "missing", via: serving[0]?.label ?? null, macOnly };
}

export function CloudModelsCard({ focus }: { focus: string | null }) {
  const models = useSettingsState().models;
  const { busy, error, run } = useModelsRun();
  const [sheet, setSheet] = useState<{ start: SheetStart } | null>(null);
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
              onSetUp={(start) => setSheet({ start })}
            />
          ))
        )}
      </div>
      {sheet && (
        <AddConnectionSheet models={models} busy={busy} run={run} start={sheet.start} onClose={() => setSheet(null)} />
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
  onSetUp(start: SheetStart): void;
}) {
  const router = useSettingsRouter();
  const { state, via, macOnly } = cloudReadiness(models, row);
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
          <div className="row-title">{title}</div>
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
      {row === "chatgpt" && pending && (
        <div className="accounts-body">
          <ChatGPTStatus chatgpt={models.chatgpt} busy={busy} run={run} />
        </div>
      )}
    </div>
  );
}
