// Settings > Cloud > Models for Cloud (cmux-tui/docs/model-connections.md, Revision 2): whether a Cloud
// chat on Claude, on ChatGPT (Codex) or on an API key has a connection that serves it, one row each. The
// card names only connections that serve Cloud (servesCloud): a Mac login that cannot reach Cloud is not
// listed or explained here (Settings > Models marks it This Mac only). A row is Connected for Cloud by the
// rule a Cloud start uses (CloudSetup.swift `choice`): an enabled, signed-in personal connection that
// serves Cloud and the family, else the team's shared key for it. Each row fixes itself in place: Sign in
// with ChatGPT runs `connectChatGPT` (with the plan's id when it signed out, a reauth), Turn On runs
// `enable` on a connection turned off, and Set Up opens Settings > Models' own Add a Connection steps
// (`claudeSetupToken` and `addClaudeToken`, `addKey`); this card adds no second way in.
// `?focus=cloud.claude`, `cloud.chatgpt` or `cloud.apiKey` (the chat's Set up Cloud card,
// cmux://settings/cloud/...) opens the page on that row.
import { useState } from "react";
import { AgentMark } from "../../../agent-session/shared/AgentMark";
import { Button } from "../../../ui/Button";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../../ui/Menu";
import { useSettingsState } from "../context";
import { Icon } from "../icons";
import { revealRow } from "../keyboard";
import type { ModelConnection, ModelProvider, ModelsState } from "../ops";
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

/** One row's state: `ready` (a Cloud chat starts on `via`), `off` (`connection` would serve it but is
 * turned off or signed out), `missing` (nothing serves it). Only connections that serve Cloud count. */
export type CloudReadiness = {
  state: "ready" | "off" | "missing";
  via: string | null;
  connection: ModelConnection | null;
};

const works = (connection: ModelConnection) => connection.enabled && connection.signedIn;

/** A row's readiness from the models read, by the rule a Cloud start uses. */
export function cloudReadiness(models: ModelsState, row: CloudRow): CloudReadiness {
  const connections = models.personal.connections;
  if (row === "apiKey") {
    return readiness(connections.filter((c) => c.kind === "api-key" && c.servesCloud));
  }
  const family = row === "claude" ? "claude" : "codex";
  const serving = connections.filter((c) => c.servesCloud && c.families.includes(family));
  const own = readiness(serving);
  if (own.state === "ready") return own;
  const team = models.organization.team && models.organization.keys.some((key) => key.agent === family && key.set);
  // The team's shared key serves the family after the person's own (Settings > Models' Organization).
  if (team) return { state: "ready", via: t("settingsWindow.models.org.key", AGENT_NAMES[family]), connection: null };
  return own;
}

/** The person's own connections that serve the row: ready on the first that works, else off on the
 * first one (the one its button fixes), else missing. */
function readiness(serving: ModelConnection[]): CloudReadiness {
  const ready = serving.find(works);
  if (ready) return { state: "ready", via: ready.label, connection: ready };
  const first = serving[0] ?? null;
  return { state: first ? "off" : "missing", via: first?.label ?? null, connection: first };
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
  const { state, via, connection } = cloudReadiness(models, row);
  const title = row === "apiKey" ? t("settingsWindow.harnesses.accounts.apiKey") : ROW_NAMES[row];
  // Off: signed out needs a sign-in (a ChatGPT plan's reauth); turned off needs Turn On.
  const signedOut = state === "off" && connection !== null && !connection.signedIn;
  const turnedOff = state === "off" && connection !== null && connection.signedIn && !connection.enabled;
  const status =
    state === "ready"
      ? t("settingsWindow.cloud.status.ready")
      : signedOut
        ? t("settingsWindow.harnesses.signedOut")
        : turnedOff
          ? t("settingsWindow.cloud.status.turnedOff")
          : t("settingsWindow.cloud.status.missing");
  // Sign in with ChatGPT: a new plan, or the signed-out plan's own sign-in again (`id`). A plan that is
  // both turned off and signed out is turned on as it signs in, so one press serves Cloud.
  const plan = connection?.kind === "chatgpt-plan" ? connection : null;
  const signInChatGPT = async () => {
    if (plan && !plan.enabled && !(await run({ action: "enable", id: plan.id, on: true }))) return;
    await run(plan ? { action: "connectChatGPT", id: plan.id } : { action: "connectChatGPT" });
  };
  // Nothing serves the row, or what would is signed out: the row's own way in.
  const needsSetUp = state === "missing" || signedOut;
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
        </div>
        <div className="accounts-buttons">
          {turnedOff && connection && (
            <Button
              type="button"
              className="button"
              variant="solid"
              data-cloud-action="turnOn"
              disabled={busy}
              onClick={() => void run({ action: "enable", id: connection.id, on: true })}
            >
              {t("settingsWindow.cloud.turnOn")}
            </Button>
          )}
          {needsSetUp && row === "claude" && (
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
          {needsSetUp && row === "chatgpt" && !pending && (
            <Button
              type="button"
              className="button"
              variant="solid"
              data-cloud-action="connectChatGPT"
              disabled={busy}
              onClick={() => void signInChatGPT()}
            >
              {t("settingsWindow.cloud.chatgpt.signIn")}
            </Button>
          )}
          {needsSetUp && row === "apiKey" && (
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
