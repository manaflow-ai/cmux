// Settings > Models (cmux-tui/docs/model-connections.md): which subscription or key each thread runs
// on. Your connections lists this person's Mac logins, ChatGPT plan sign-ins and API keys in the order
// a thread tries them (drag a row, or Move Up / Move Down in its menu), each with its routing switch,
// plus Spread usage. Organization connections lists the team's shared keys, which
// every member's threads use after their own; owners and admins add, replace and remove the keys.
// Members holds the team's policy for members' own connections, editable only by owners and admins.
// Add a Connection (the "+", or `#/settings/models?focus=models.add`, which cmux://settings/models/add
// opens) is a sheet with a search field: Subscriptions (ChatGPT through Continue with ChatGPT; Claude
// Code through `claude setup-token` in a cmux terminal tab and a paste field for the token it prints)
// and API keys (a password field and an optional label). A pasted key or token lives only in the open
// form until it is sent, then is cleared; the app moves it into the Keychain and the page never sees it
// again. A Mac login Cloud threads cannot use (servesCloud false) says This Mac only (Revision 2).
import { useEffect, useId, useRef, useState, type DragEvent } from "react";
import { AgentMark } from "../../../agent-session/shared/AgentMark";
import { Button } from "../../../ui/Button";
import { Dialog } from "../../../ui/Dialog";
import { Input } from "../../../ui/Input";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../../ui/Menu";
import { useSettingsState, useStore } from "../context";
import { Select } from "../editors/Select";
import { Switch } from "../editors/ToggleEditor";
import { planName } from "../harnesses";
import { Icon } from "../icons";
import type { ModelConnection, ModelProvider, ModelsRun, ModelsState } from "../ops";
import { t } from "../strings";

/** The route focus that opens Add a Connection (cmux://settings/models/add). */
export const MODELS_ADD_FOCUS = "models.add";
/** Where a ChatGPT plan's usage is managed (the plan's own page). */
export const CHATGPT_USAGE_URL = "https://chatgpt.com/settings/usage";

/** Product names, shown as they are in every language. */
const PROVIDERS: Record<ModelProvider, string> = {
  anthropic: "Anthropic",
  openai: "OpenAI",
  openrouter: "OpenRouter",
  google: "Google",
  xai: "xAI",
};
const KEY_PROVIDERS: ModelProvider[] = ["anthropic", "openai", "openrouter", "google", "xai"];
const AGENT_NAMES: Record<"claude" | "codex", string> = { claude: "Claude", codex: "Codex" };

/** The brand mark a connection shows (agentBrands.generated.ts names). */
function markOf(connection: Pick<ModelConnection, "kind" | "provider">): string {
  if (connection.kind === "claude-login" || connection.kind === "claude-token") return "claude";
  if (connection.kind === "codex-login" || connection.kind === "chatgpt-plan") return "openai";
  return (
    { anthropic: "anthropic", openai: "openai", openrouter: "openrouter", google: "gemini", xai: "grok" } as const
  )[connection.provider];
}

/** "Authenticated as alex@example.com · ChatGPT Pro", "API key", or "Not signed in". */
export function connectionAuthText(connection: ModelConnection): string {
  if (!connection.signedIn) return t("settingsWindow.harnesses.notAuthenticated");
  if (connection.kind === "api-key") return t("settingsWindow.harnesses.accounts.apiKey");
  const plan = planName(connection.families[0] ?? "", connection.plan);
  if (connection.email) {
    return plan
      ? t("settingsWindow.harnesses.accounts.authenticatedAsPlan", connection.email, plan)
      : t("settingsWindow.harnesses.accounts.authenticatedAs", connection.email);
  }
  return plan ? t("settingsWindow.harnesses.authenticatedPlan", plan) : t("settingsWindow.harnesses.authenticated");
}

/** A ChatGPT sign-in's failure code in plain words. */
export function chatgptErrorText(code: string): string {
  if (code === "access_denied") return t("settingsWindow.models.chatgpt.errorDenied");
  if (code === "no_plan_scope") return t("settingsWindow.models.chatgpt.errorNoPlan");
  return t("settingsWindow.models.chatgpt.errorOther");
}

/** `ids` with `id` moved to `to` (an index into the list). */
export function moveId(ids: string[], id: string, to: number): string[] {
  const rest = ids.filter((other) => other !== id);
  rest.splice(Math.max(0, Math.min(to, rest.length)), 0, id);
  return rest;
}

type Run = (gesture: ModelsRun) => Promise<boolean>;

export function ModelsCard({ focus }: { focus: string | null }) {
  const models = useSettingsState().models;
  const store = useStore();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [adding, setAdding] = useState(focus === MODELS_ADD_FOCUS);
  useEffect(() => {
    if (focus === MODELS_ADD_FOCUS) setAdding(true);
  }, [focus]);
  if (!models) return null;
  /** Sends a gesture; resolves whether the host took it (a refusal shows under the card). */
  const run: Run = (gesture) => {
    setBusy(true);
    setError(null);
    return store
      .runModels(gesture)
      .then(
        () => true,
        (failure: unknown) => {
          setError(failure instanceof Error ? failure.message : String(failure));
          return false;
        },
      )
      .finally(() => setBusy(false));
  };
  return (
    <div className="models" data-card="models" aria-busy={busy}>
      <p className="row-help models-lead">{t("settingsWindow.models.subtitle")}</p>
      {error && (
        <p className="row-error" role="alert" data-models-error="">
          {error}
        </p>
      )}
      <PersonalSection models={models} busy={busy} run={run} onAdd={() => setAdding(true)} />
      <OrganizationSection models={models} busy={busy} run={run} />
      {models.members && <MembersSection members={models.members} busy={busy} run={run} />}
      {adding && <AddConnectionSheet models={models} busy={busy} run={run} onClose={() => setAdding(false)} />}
    </div>
  );
}

function SectionHeader({ title, help, children }: { title: string; help: string; children?: React.ReactNode }) {
  return (
    <div className="models-header">
      <div>
        <h3 className="group-title">{title}</h3>
        <p className="row-help">{help}</p>
      </div>
      {children}
    </div>
  );
}

function AddButton({
  label,
  disabled,
  onClick,
  id,
}: {
  label: string;
  disabled: boolean;
  onClick(): void;
  id: string;
}) {
  return (
    <Button
      type="button"
      className="button models-add"
      aria-label={label}
      title={label}
      data-models-action={id}
      disabled={disabled}
      onClick={onClick}
    >
      <Icon name="plus" />
    </Button>
  );
}

function ChatGPTStatus({ chatgpt, busy, run }: { chatgpt: ModelsState["chatgpt"]; busy: boolean; run: Run }) {
  if (chatgpt.attempt) {
    return (
      <output className="models-chatgpt" data-chatgpt="pending">
        <span className="row-help">{t("settingsWindow.models.chatgpt.waiting")}</span>
        <Button
          type="button"
          className="button"
          data-models-action="cancelChatGPT"
          disabled={busy}
          onClick={() => void run({ action: "cancelChatGPT" })}
        >
          {t("settingsWindow.cancel")}
        </Button>
      </output>
    );
  }
  if (chatgpt.error) {
    return (
      <div className="models-chatgpt" data-chatgpt="error">
        <span className="row-error" role="alert">
          {chatgptErrorText(chatgpt.error)}
        </span>
        <Button
          type="button"
          className="button"
          data-models-action="retryChatGPT"
          disabled={busy}
          onClick={() => void run({ action: "connectChatGPT" })}
        >
          {t("settingsWindow.models.tryAgain")}
        </Button>
      </div>
    );
  }
  return null;
}

function PersonalSection({
  models,
  busy,
  run,
  onAdd,
}: {
  models: ModelsState;
  busy: boolean;
  run: Run;
  onAdd(): void;
}) {
  const spreadId = useId();
  const { connections, spread, available } = models.personal;
  const [dragging, setDragging] = useState<string | null>(null);
  const ids = connections.map((connection) => connection.id);
  const order = (next: string[]) => {
    if (next.join("\n") !== ids.join("\n")) void run({ action: "order", ids: next });
  };
  return (
    <section className="group" data-models-section="personal">
      <SectionHeader title={t("settingsWindow.models.personal.title")} help={t("settingsWindow.models.personal.help")}>
        <AddButton label={t("settingsWindow.models.add")} id="add" disabled={busy || !available} onClick={onAdd} />
      </SectionHeader>
      <ChatGPTStatus chatgpt={models.chatgpt} busy={busy} run={run} />
      <div className="rows">
        {!available && (
          <div className="row" data-empty="">
            <span className="row-help">{t("settingsWindow.models.personal.unavailable")}</span>
          </div>
        )}
        {available && connections.length === 0 && (
          <div className="row" data-empty="">
            <span className="row-help">{t("settingsWindow.models.personal.empty")}</span>
          </div>
        )}
        {connections.map((connection, index) => (
          <ConnectionRow
            key={connection.id}
            connection={connection}
            index={index}
            count={connections.length}
            busy={busy}
            run={run}
            dragging={dragging === connection.id}
            onDragStart={() => setDragging(connection.id)}
            onDragEnd={() => setDragging(null)}
            onDrop={() => {
              if (dragging) order(moveId(ids, dragging, index));
              setDragging(null);
            }}
            onMove={(to) => order(moveId(ids, connection.id, to))}
          />
        ))}
      </div>
      <div className="rows">
        <div className="row" data-models-row="spread">
          <div className="row-main">
            <div className="row-label" id={spreadId}>
              <div className="row-title">{t("settingsWindow.models.spread.title")}</div>
              <div className="row-help">{t("settingsWindow.models.spread.help")}</div>
            </div>
            <div className="row-control">
              <Switch
                checked={spread}
                disabled={busy || !available}
                labelId={spreadId}
                onToggle={(on) => void run({ action: "spread", on })}
              />
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

function ConnectionRow({
  connection,
  index,
  count,
  busy,
  run,
  dragging,
  onDragStart,
  onDragEnd,
  onDrop,
  onMove,
}: {
  connection: ModelConnection;
  index: number;
  count: number;
  busy: boolean;
  run: Run;
  dragging: boolean;
  onDragStart(): void;
  onDragEnd(): void;
  onDrop(): void;
  onMove(to: number): void;
}) {
  const nameId = useId();
  const [confirming, setConfirming] = useState(false);
  const builtin = connection.kind === "codex-login" || connection.kind === "claude-login";
  const plan = connection.kind === "chatgpt-plan";
  const reauth: ModelsRun | null = plan
    ? { action: "connectChatGPT", id: connection.id }
    : connection.kind === "claude-login"
      ? { action: "connectClaude" }
      : null;
  const over = (event: DragEvent) => {
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";
  };
  return (
    <div
      className="row models-connection"
      data-connection={connection.id}
      data-dragging={dragging ? "" : undefined}
      onDragOver={over}
      onDrop={(event) => {
        event.preventDefault();
        onDrop();
      }}
    >
      <div className="row-main">
        <span
          className="models-grip"
          draggable={!busy && count > 1}
          aria-hidden="true"
          onDragStart={(event) => {
            event.dataTransfer.effectAllowed = "move";
            event.dataTransfer.setData("text/plain", connection.id);
            onDragStart();
          }}
          onDragEnd={onDragEnd}
        >
          <Icon name="grip" />
        </span>
        <span className="accounts-mark" aria-hidden="true">
          <AgentMark agent={markOf(connection)} size={16} />
        </span>
        <div className="row-label">
          <div className="row-title" id={nameId}>
            {connection.label}
            {connection.defaultFor.length > 0 && (
              <span className="accounts-badge" data-connection-default="">
                {t("settingsWindow.harnesses.accounts.default")}
              </span>
            )}
          </div>
          <div className="row-help" data-connection-auth={connection.signedIn ? "signedIn" : "signedOut"}>
            {connectionAuthText(connection)}
          </div>
          {!connection.servesCloud && (
            <div className="row-help" data-connection-local="">
              {t("settingsWindow.models.thisMacOnly")}
            </div>
          )}
          {plan && (
            <div className="row-help" data-chatgpt-plan="">
              {t("settingsWindow.models.chatgptPlan")}
              {" · "}
              <a className="channel-link" href={CHATGPT_USAGE_URL} target="_blank" rel="noreferrer">
                {t("settingsWindow.models.manageUsage")}
              </a>
            </div>
          )}
        </div>
        <div className="row-control">
          <Switch
            checked={connection.enabled}
            disabled={busy}
            labelId={nameId}
            onToggle={(on) => void run({ action: "enable", id: connection.id, on })}
          />
          <Menu>
            <MenuButton
              className="button models-more"
              label={t("settingsWindow.models.more", connection.label)}
              data-menu={`connection-${connection.id}`}
              disabled={busy}
            >
              <Icon name="ellipsis" />
            </MenuButton>
            <MenuPopup align="end">
              <MenuItem data-value="moveUp" disabled={index === 0} onSelect={() => onMove(index - 1)}>
                {t("settingsWindow.models.moveUp")}
              </MenuItem>
              <MenuItem data-value="moveDown" disabled={index === count - 1} onSelect={() => onMove(index + 1)}>
                {t("settingsWindow.models.moveDown")}
              </MenuItem>
              {reauth && (
                <MenuItem data-value="signInAgain" onSelect={() => void run(reauth)}>
                  {t("settingsWindow.models.signInAgain")}
                </MenuItem>
              )}
              {!builtin && (
                <MenuItem data-value="remove" onSelect={() => setConfirming(true)}>
                  {t("settingsWindow.remove")}
                </MenuItem>
              )}
            </MenuPopup>
          </Menu>
        </div>
      </div>
      {confirming && (
        <div className="accounts-body">
          <div className="accounts-form" role="alertdialog" aria-labelledby={nameId} data-connection-remove="">
            <span className="row-help">{t("settingsWindow.models.removeConfirm", connection.label)}</span>
            <div className="accounts-buttons">
              <Button
                danger
                type="button"
                className="button danger"
                data-models-action="confirmRemove"
                disabled={busy}
                onClick={() => {
                  setConfirming(false);
                  void run({ action: "remove", id: connection.id });
                }}
              >
                {t("settingsWindow.remove")}
              </Button>
              <Button type="button" className="button" onClick={() => setConfirming(false)}>
                {t("settingsWindow.cancel")}
              </Button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

function OrganizationSection({ models, busy, run }: { models: ModelsState; busy: boolean; run: Run }) {
  const { team, canEdit, keys } = models.organization;
  const [adding, setAdding] = useState(false);
  const unset = keys.find((key) => !key.set)?.agent ?? null;
  return (
    <section className="group" data-models-section="organization">
      <SectionHeader title={t("settingsWindow.models.org.title")} help={t("settingsWindow.models.org.help")}>
        {team && canEdit && (
          <AddButton
            label={t("settingsWindow.models.org.add")}
            id="orgAdd"
            disabled={busy || unset === null || adding}
            onClick={() => setAdding(true)}
          />
        )}
      </SectionHeader>
      <div className="rows">
        {!team && (
          <div className="row" data-empty="">
            <span className="row-help">{t("settingsWindow.models.org.noTeam")}</span>
          </div>
        )}
        {team && keys.every((key) => !key.set) && !adding && (
          <div className="row" data-empty="">
            <span className="row-help">{t("settingsWindow.models.org.empty")}</span>
          </div>
        )}
        {team &&
          keys
            .filter((key) => key.set)
            .map((key) => (
              <OrgKeyRow key={key.agent} agent={key.agent} last4={key.last4} canEdit={canEdit} busy={busy} run={run} />
            ))}
        {team && canEdit && adding && unset && (
          <OrgKeyForm
            agents={keys.filter((key) => !key.set).map((key) => key.agent)}
            busy={busy}
            run={run}
            onDone={() => setAdding(false)}
          />
        )}
        {team && !canEdit && (
          <div className="row">
            <span className="row-help" data-models-note="">
              {t("settingsWindow.models.org.readOnly")}
            </span>
          </div>
        )}
      </div>
    </section>
  );
}

function OrgKeyRow({
  agent,
  last4,
  canEdit,
  busy,
  run,
}: {
  agent: "claude" | "codex";
  last4: string | null;
  canEdit: boolean;
  busy: boolean;
  run: Run;
}) {
  const [mode, setMode] = useState<"idle" | "edit" | "confirm">("idle");
  const name = t("settingsWindow.models.org.key", AGENT_NAMES[agent]);
  return (
    <div className="row accounts-row" data-org-key={agent}>
      <div className="row-main">
        <span className="accounts-mark" aria-hidden="true">
          <AgentMark agent={agent} size={16} />
        </span>
        <div className="row-label">
          <div className="row-title">{name}</div>
          <div className="row-help">
            {last4 ? t("settingsWindow.models.org.keyEnds", last4) : t("settingsWindow.models.org.keySet")}
          </div>
        </div>
        {canEdit && mode === "idle" && (
          <div className="accounts-buttons">
            <Button
              type="button"
              className="button"
              data-models-action="orgReplace"
              disabled={busy}
              onClick={() => setMode("edit")}
            >
              {t("settingsWindow.models.org.replace")}
            </Button>
            <Button
              danger
              type="button"
              className="button danger"
              data-models-action="orgRemove"
              disabled={busy}
              onClick={() => setMode("confirm")}
            >
              {t("settingsWindow.remove")}
            </Button>
          </div>
        )}
      </div>
      {canEdit && mode === "confirm" && (
        <div className="accounts-body">
          <div className="accounts-form" role="alertdialog">
            <span className="row-help">{t("settingsWindow.models.org.removeConfirm", name)}</span>
            <div className="accounts-buttons">
              <Button
                danger
                type="button"
                className="button danger"
                data-models-action="orgConfirmRemove"
                disabled={busy}
                onClick={() => {
                  setMode("idle");
                  void run({ action: "orgKey", agent, key: null });
                }}
              >
                {t("settingsWindow.remove")}
              </Button>
              <Button type="button" className="button" onClick={() => setMode("idle")}>
                {t("settingsWindow.cancel")}
              </Button>
            </div>
          </div>
        </div>
      )}
      {canEdit && mode === "edit" && (
        <div className="accounts-body">
          <OrgKeyForm agents={[agent]} busy={busy} run={run} onDone={() => setMode("idle")} />
        </div>
      )}
    </div>
  );
}

function OrgKeyForm({
  agents,
  busy,
  run,
  onDone,
}: {
  agents: Array<"claude" | "codex">;
  busy: boolean;
  run: Run;
  onDone(): void;
}) {
  const agentLabel = useId();
  const [agent, setAgent] = useState(agents[0] ?? "claude");
  const [key, setKey] = useState("");
  const send = () => {
    const value = key.trim();
    if (!value || busy) return;
    // The key leaves the page's state before it is sent.
    setKey("");
    onDone();
    void run({ action: "orgKey", agent, key: value });
  };
  return (
    <form
      className="accounts-form"
      data-org-key-form=""
      onSubmit={(event) => {
        event.preventDefault();
        send();
      }}
    >
      {agents.length > 1 && (
        <div className="row-main">
          <div className="row-label">
            <div className="row-title" id={agentLabel}>
              {t("settingsWindow.models.org.agent")}
            </div>
          </div>
          <div className="row-control">
            <Select
              value={agent}
              disabled={busy}
              labelId={agentLabel}
              onChange={(value) => setAgent(value === "codex" ? "codex" : "claude")}
            >
              {agents.map((option) => (
                <option key={option} value={option}>
                  {AGENT_NAMES[option]}
                </option>
              ))}
            </Select>
          </div>
        </div>
      )}
      <Input
        className="field"
        type="password"
        aria-label={t("settingsWindow.models.key.field")}
        autoComplete="off"
        spellCheck={false}
        maxLength={4096}
        value={key}
        onChange={(event) => setKey(event.target.value)}
      />
      <div className="accounts-buttons">
        <Button type="submit" className="button" data-models-action="orgSave" disabled={busy || !key.trim()}>
          {t("settingsWindow.models.key.add")}
        </Button>
        <Button
          type="button"
          className="button"
          onClick={() => {
            setKey("");
            onDone();
          }}
        >
          {t("settingsWindow.cancel")}
        </Button>
      </div>
    </form>
  );
}

function MembersSection({
  members,
  busy,
  run,
}: {
  members: NonNullable<ModelsState["members"]>;
  busy: boolean;
  run: Run;
}) {
  const ownId = useId();
  const runoutId = useId();
  const rows = [
    {
      id: ownId,
      row: "ownConnections",
      title: t("settingsWindow.models.members.own"),
      help: t("settingsWindow.models.members.ownHelp"),
      checked: members.ownConnections,
      toggle: (on: boolean) => void run({ action: "members", ownConnections: on }),
    },
    {
      id: runoutId,
      row: "chooseRunout",
      title: t("settingsWindow.models.members.runout"),
      help: t("settingsWindow.models.members.runoutHelp"),
      checked: members.chooseRunout,
      toggle: (on: boolean) => void run({ action: "members", chooseRunout: on }),
    },
  ];
  return (
    <section className="group" data-models-section="members">
      <SectionHeader title={t("settingsWindow.models.members.title")} help={t("settingsWindow.models.members.help")} />
      <div className="rows">
        {rows.map((row) => (
          <div className="row" key={row.row} data-models-row={row.row}>
            <div className="row-main">
              <div className="row-label" id={row.id}>
                <div className="row-title">{row.title}</div>
                <div className="row-help">{row.help}</div>
              </div>
              <div className="row-control">
                <Switch
                  checked={row.checked}
                  disabled={busy || !members.canEdit}
                  labelId={row.id}
                  onToggle={row.toggle}
                />
              </div>
            </div>
          </div>
        ))}
        {!members.canEdit && (
          <div className="row">
            <span className="row-help" data-models-note="">
              {t("settingsWindow.models.members.readOnly")}
            </span>
          </div>
        )}
      </div>
    </section>
  );
}

type Choice =
  | { kind: "chatgpt"; title: string; detail: string }
  | { kind: "claude"; title: string; detail: string }
  | { kind: "key"; provider: ModelProvider; title: string; detail: string };

const SUBSCRIPTIONS: Choice[] = [
  { kind: "chatgpt", title: "ChatGPT", detail: "chatgpt.com" },
  { kind: "claude", title: "Claude Code", detail: "claude.ai" },
];

function AddConnectionSheet({
  models,
  busy,
  run,
  onClose,
}: {
  models: ModelsState;
  busy: boolean;
  run: Run;
  onClose(): void;
}) {
  const [query, setQuery] = useState("");
  const [picked, setPicked] = useState<Choice | null>(null);
  const keys: Choice[] = KEY_PROVIDERS.map((provider) => ({
    kind: "key",
    provider,
    title: PROVIDERS[provider],
    detail: t("settingsWindow.models.sheet.apiKey"),
  }));
  const needle = query.trim().toLocaleLowerCase();
  const matches = (choice: Choice) =>
    !needle || `${choice.title} ${choice.detail}`.toLocaleLowerCase().includes(needle);
  const groups = [
    {
      id: "subscriptions",
      title: t("settingsWindow.models.sheet.subscriptions"),
      choices: SUBSCRIPTIONS.filter(matches),
    },
    { id: "keys", title: t("settingsWindow.models.sheet.apiKeys"), choices: keys.filter(matches) },
  ].filter((group) => group.choices.length > 0);
  // A ChatGPT sign-in that finishes with a new connection closes the sheet; Cancel or a failure keeps it.
  const { attempt, error } = models.chatgpt;
  const count = models.personal.connections.length;
  const before = useRef<number | null>(null);
  useEffect(() => {
    if (attempt) before.current ??= count;
    else if (before.current !== null) {
      const added = !error && count > before.current;
      before.current = null;
      if (added) onClose();
    }
  }, [attempt, error, count, onClose]);
  const title = t("settingsWindow.models.add");
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
      label={title}
      className="ui-glass ui-glass-floats models-sheet"
    >
      <div className="models-sheet-body" data-models-sheet="">
        <header className="models-sheet-header">
          {picked && (
            <Button type="button" className="button" data-models-action="back" onClick={() => setPicked(null)}>
              {t("settingsWindow.models.sheet.back")}
            </Button>
          )}
          <h2>{picked ? picked.title : title}</h2>
        </header>
        {!picked && (
          <>
            <Input
              className="field"
              type="search"
              aria-label={t("settingsWindow.models.sheet.search")}
              placeholder={t("settingsWindow.models.sheet.search")}
              autoComplete="off"
              spellCheck={false}
              value={query}
              onChange={(event) => setQuery(event.target.value)}
            />
            {groups.length === 0 && <p className="row-help">{t("settingsWindow.models.sheet.noMatch")}</p>}
            {groups.map((group) => (
              <div key={group.id} className="models-sheet-group" data-models-group={group.id}>
                <h3 className="group-title">{group.title}</h3>
                <div className="models-sheet-choices">
                  {group.choices.map((choice) => (
                    <button
                      key={choice.kind === "key" ? choice.provider : choice.kind}
                      type="button"
                      className="models-sheet-choice"
                      data-models-choice={choice.kind === "key" ? choice.provider : choice.kind}
                      onClick={() => setPicked(choice)}
                    >
                      <span className="accounts-mark" aria-hidden="true">
                        <AgentMark
                          agent={
                            choice.kind === "key"
                              ? markOf({ kind: "api-key", provider: choice.provider })
                              : choice.kind === "chatgpt"
                                ? "openai"
                                : "claude"
                          }
                          size={16}
                        />
                      </span>
                      <span className="models-sheet-choice-text">
                        <strong>{choice.title}</strong>
                        <small>{choice.detail}</small>
                      </span>
                    </button>
                  ))}
                </div>
              </div>
            ))}
          </>
        )}
        {picked?.kind === "chatgpt" && (
          <div className="accounts-form" data-models-way="chatgpt">
            <p className="row-help">{t("settingsWindow.models.chatgpt.help")}</p>
            {attempt || error ? (
              <ChatGPTStatus chatgpt={models.chatgpt} busy={busy} run={run} />
            ) : (
              <div className="accounts-buttons">
                <Button
                  type="button"
                  className="button"
                  variant="solid"
                  data-models-action="connectChatGPT"
                  disabled={busy}
                  onClick={() => void run({ action: "connectChatGPT" })}
                >
                  {t("settingsWindow.models.chatgpt.continue")}
                </Button>
              </div>
            )}
          </div>
        )}
        {picked?.kind === "claude" && <ClaudeTokenForm busy={busy} run={run} onDone={onClose} />}
        {picked?.kind === "key" && <KeyForm provider={picked.provider} busy={busy} run={run} onDone={onClose} />}
      </div>
    </Dialog>
  );
}

function KeyForm({
  provider,
  busy,
  run,
  onDone,
}: {
  provider: ModelProvider;
  busy: boolean;
  run: Run;
  onDone(): void;
}) {
  const keyId = useId();
  const labelId = useId();
  const [key, setKey] = useState("");
  const [label, setLabel] = useState("");
  const send = () => {
    const value = key.trim();
    if (!value || busy) return;
    const named = label.trim();
    const gesture: ModelsRun = named
      ? { action: "addKey", provider, key: value, label: named }
      : { action: "addKey", provider, key: value };
    // The key leaves the page's state before it is sent; a refusal asks for it again.
    setKey("");
    void run(gesture).then((ok) => ok && onDone());
  };
  return (
    <form
      className="accounts-form"
      data-models-way="key"
      data-models-key-form={provider}
      onSubmit={(event) => {
        event.preventDefault();
        send();
      }}
    >
      <p className="row-help">{t("settingsWindow.models.key.help", PROVIDERS[provider])}</p>
      <label className="row-help" id={keyId}>
        {t("settingsWindow.models.key.field")}
      </label>
      <Input
        className="field"
        type="password"
        aria-labelledby={keyId}
        autoComplete="off"
        spellCheck={false}
        maxLength={4096}
        value={key}
        disabled={busy}
        onChange={(event) => setKey(event.target.value)}
      />
      <label className="row-help" id={labelId}>
        {t("settingsWindow.models.key.label")}
      </label>
      <Input
        className="field"
        aria-labelledby={labelId}
        autoComplete="off"
        maxLength={128}
        placeholder={PROVIDERS[provider]}
        value={label}
        disabled={busy}
        onChange={(event) => setLabel(event.target.value)}
      />
      <div className="accounts-buttons">
        <Button type="submit" className="button" data-models-action="addKey" disabled={busy || !key.trim()}>
          {t("settingsWindow.models.key.add")}
        </Button>
        <Button
          type="button"
          className="button"
          onClick={() => {
            setKey("");
            onDone();
          }}
        >
          {t("settingsWindow.cancel")}
        </Button>
      </div>
    </form>
  );
}

/** Claude's setup token starts with this, and a pasted one has no whitespace in it. */
const CLAUDE_TOKEN = /^sk-ant-oat\S*$/;

/** Whether `token` reads as a Claude setup token (`claude setup-token` prints one). */
export function isClaudeToken(token: string): boolean {
  return CLAUDE_TOKEN.test(token);
}

/** Add a Connection > Claude Code: step 1 opens a cmux terminal tab running `claude setup-token`,
 * step 2 takes the token it prints. The token leaves the page's state before it is sent. */
function ClaudeTokenForm({ busy, run, onDone }: { busy: boolean; run: Run; onDone(): void }) {
  const tokenId = useId();
  const labelId = useId();
  const [token, setToken] = useState("");
  const [label, setLabel] = useState("");
  const pasted = token.trim();
  const valid = isClaudeToken(pasted);
  const send = () => {
    if (!valid || busy) return;
    const named = label.trim();
    setToken("");
    void run(
      named ? { action: "addClaudeToken", token: pasted, label: named } : { action: "addClaudeToken", token: pasted },
    ).then((ok) => ok && onDone());
  };
  return (
    <form
      className="accounts-form"
      data-models-way="claude"
      data-models-claude-form=""
      onSubmit={(event) => {
        event.preventDefault();
        send();
      }}
    >
      <p className="row-help">{t("settingsWindow.models.claude.help")}</p>
      <div className="row-title">{t("settingsWindow.models.claude.step1")}</div>
      <div className="accounts-buttons">
        <Button
          type="button"
          className="button"
          data-models-action="claudeSetupToken"
          disabled={busy}
          onClick={() => void run({ action: "claudeSetupToken" })}
        >
          {t("settingsWindow.models.claude.openTerminal")}
        </Button>
      </div>
      <label className="row-title" id={tokenId}>
        {t("settingsWindow.models.claude.step2")}
      </label>
      <Input
        className="field"
        type="password"
        aria-labelledby={tokenId}
        autoComplete="off"
        spellCheck={false}
        maxLength={4096}
        value={token}
        disabled={busy}
        onChange={(event) => setToken(event.target.value)}
      />
      {pasted !== "" && !valid && (
        <p className="row-error" role="alert" data-claude-token-invalid="">
          {t("settingsWindow.models.claude.invalid")}
        </p>
      )}
      <label className="row-help" id={labelId}>
        {t("settingsWindow.models.key.label")}
      </label>
      <Input
        className="field"
        aria-labelledby={labelId}
        autoComplete="off"
        maxLength={128}
        placeholder="Claude Code"
        value={label}
        disabled={busy}
        onChange={(event) => setLabel(event.target.value)}
      />
      <div className="accounts-buttons">
        <Button type="submit" className="button" data-models-action="addClaudeToken" disabled={busy || !valid}>
          {t("settingsWindow.models.claude.add")}
        </Button>
        <Button
          type="button"
          className="button"
          onClick={() => {
            setToken("");
            onDone();
          }}
        >
          {t("settingsWindow.cancel")}
        </Button>
      </div>
    </form>
  );
}
