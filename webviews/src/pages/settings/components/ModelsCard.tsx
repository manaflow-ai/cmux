// Settings > Models (cmux-tui/docs/model-connections.md): which subscription or key each thread runs
// on. Your connections lists this person's Mac logins, ChatGPT plan sign-ins, API keys and Microsoft
// Foundry once set up (This Mac only; its own spinner; Add a Connection > Cloud providers walks its
// setup) in the order a thread tries them (drag a row, or Move Up / Move Down in its menu; Foundry
// reorders the same way, its placement kept even though a thread picks it, not falls back to it),
// each with its routing switch, plus Spread usage. Organization connections lists the
// team's shared keys, which every member's threads use after their own; owners and admins add,
// replace and remove the keys. Members holds the team's policy for members' own connections,
// editable only by owners and admins. Add a Connection (the "+", or `#/settings/models?focus=models.add`,
// which cmux://settings/models/add opens) is a sheet with a search field: Subscriptions (ChatGPT
// through Continue with ChatGPT; Claude Code through `claude setup-token` in a cmux terminal tab and a
// paste field for the token it prints), API keys (a password field and an optional label), and Cloud
// providers (Microsoft Foundry's setup). Foundry's ⋯ menu opens a small region dialog on the row,
// and a failure there is the row's own error, not another screen. A pasted key or token lives only in the open form until it is
// sent, then is cleared; the app moves it into the Keychain and the page never sees it again. A Mac
// login Cloud threads cannot use (servesCloud false) says This Mac only (Revision 2), with Set Up for
// Cloud, which opens Settings > Cloud on the row that sets one up (CloudModelsCard.tsx).
// A Claude login's Sign In Again, on a host that signs in in place, shows the sign-in card under the
// row (logins done right; Leo, 2026-11-22: "this is simply logins, done righr."): the CLI's own login
// when it is signed out, else a new Claude account, as the host's `connectClaude` picks; a daemon
// without the in-place sign-in, or a host without it, keeps `connectClaude` (its terminal sign-in).
import { useEffect, useId, useRef, useState, type DragEvent } from "react";
import { Spinner } from "../../../agent-session/acpmux/conversation/icons";
import { AgentMark } from "../../../agent-session/shared/AgentMark";
import { isClaudeToken } from "../../../agent-session/shared/claudeSetupToken";
import { Button } from "../../../ui/Button";
import { Dialog, DialogTitle } from "../../../ui/Dialog";
import { Input } from "../../../ui/Input";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../../ui/Menu";
import { useSettingsRouter, useSettingsState, useStore } from "../context";
import { Select } from "../editors/Select";
import { Switch } from "../editors/ToggleEditor";
import { planName } from "../harnesses";
import { Icon } from "../icons";
import { FOUNDRY_ROW, type ModelConnection, type ModelProvider, type ModelsRun, type ModelsState } from "../ops";
import { sectionHref } from "../router";
import { refusalOf } from "../store";
import { t } from "../strings";
import { userMessage } from "../../shared/userMessage";
import { DeviceSignInCard } from "../../shared/signIn/DeviceSignInCard";
import { parseAccountRow } from "../../shared/signIn/accountSignIn";
import { useSettingsSignIn } from "./useSettingsSignIn";
import foundryMark from "../foundry.png";

/** The route focus that opens Add a Connection (cmux://settings/models/add). */
export const MODELS_ADD_FOCUS = "models.add";
/** Where a ChatGPT plan's usage is managed (the plan's own page). */
export const CHATGPT_USAGE_URL = "https://chatgpt.com/settings/usage";

/** Product names, shown as they are in every language. */
export const PROVIDERS: Record<ModelProvider, string> = {
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
  if (code === "no_chatgpt_account") return t("settingsWindow.models.chatgpt.errorNoPlan");
  return t("settingsWindow.models.chatgpt.errorOther");
}

/** `ids` with `id` moved to `to` (an index into the list). */
export function moveId(ids: string[], id: string, to: number): string[] {
  const rest = ids.filter((other) => other !== id);
  rest.splice(Math.max(0, Math.min(to, rest.length)), 0, id);
  return rest;
}

/** The drag/reorder wiring a row (a connection or Foundry) gets: its spot, the list length, and the
 * gestures its grip and Move Up/Down menu fire. `busy` is the list's own ordering gesture. */
type RowDrag = {
  index: number;
  count: number;
  busy: boolean;
  dragging: boolean;
  onDragStart(): void;
  onDragEnd(): void;
  onDrop(): void;
  onMove(to: number): void;
};

/** Let a drop land on a row. */
const dragOver = (event: DragEvent) => {
  event.preventDefault();
  event.dataTransfer.dropEffect = "move";
};

/** A row's drag handle, shared by every connection row. */
function Grip({ id, drag }: { id: string; drag: RowDrag }) {
  return (
    <span
      className="models-grip"
      draggable={!drag.busy && drag.count > 1}
      aria-hidden="true"
      onDragStart={(event) => {
        event.dataTransfer.effectAllowed = "move";
        event.dataTransfer.setData("text/plain", id);
        drag.onDragStart();
      }}
      onDragEnd={drag.onDragEnd}
    >
      <Icon name="grip" />
    </span>
  );
}

/** The row container every connection shares: a drop target that reports its drag state. */
function rowDrop(drag: RowDrag) {
  return {
    "data-dragging": drag.dragging ? "" : undefined,
    onDragOver: dragOver,
    onDrop: (event: DragEvent) => {
      event.preventDefault();
      drag.onDrop();
    },
  };
}

export type Run = (gesture: ModelsRun) => Promise<boolean>;

/** A card's gestures to the host: `run` sends one and resolves whether the host took it; `busy` while
 * one is out, `error` the last refusal's sentence, `detail` the host's own message when it says more. */
export function useModelsRun(): { busy: boolean; error: string | null; detail: string | null; run: Run } {
  const store = useStore();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [detail, setDetail] = useState<string | null>(null);
  const run: Run = (gesture) => {
    setBusy(true);
    setError(null);
    setDetail(null);
    return store
      .runModels(gesture)
      .then(
        (refusal) => {
          setError(refusal?.summary ?? null);
          setDetail(refusal?.detail ?? null);
          return refusal == null;
        },
        (failure: unknown) => {
          const refusal = refusalOf(failure);
          setError(refusal.summary);
          setDetail(refusal.detail);
          return false;
        },
      )
      .finally(() => setBusy(false));
  };
  return { busy, error, detail, run };
}

/** The Settings > Cloud row (CloudModelsCard.tsx) that sets up what a This Mac only connection serves. */
export function cloudFocusOf(connection: Pick<ModelConnection, "kind" | "families">): string {
  if (connection.kind === "api-key") return "cloud.apiKey";
  return connection.families.includes("codex") ? "cloud.chatgpt" : "cloud.claude";
}

export function ModelsCard({ focus }: { focus: string | null }) {
  const store = useStore();
  const models = useSettingsState().models;
  const { busy, error, detail, run } = useModelsRun();
  const [adding, setAdding] = useState(focus === MODELS_ADD_FOCUS);
  useEffect(() => {
    if (focus === MODELS_ADD_FOCUS) setAdding(true);
  }, [focus]);
  // Whether the host signs in in place (its sign-in accounts), for a Claude login's Sign In Again.
  useEffect(() => {
    void store.refreshAccounts();
  }, [store]);
  if (!models) return null;
  return (
    <div className="models" data-card="models" aria-busy={busy}>
      <p className="row-help models-lead">{t("settingsWindow.models.subtitle")}</p>
      {error && <RunError key={`${error}\0${detail ?? ""}`} summary={error} detail={detail} />}
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

export function ChatGPTStatus({ chatgpt, busy, run }: { chatgpt: ModelsState["chatgpt"]; busy: boolean; run: Run }) {
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
  const foundry = foundryListed(models.foundry) ? models.foundry : null;
  const [dragging, setDragging] = useState<string | null>(null);
  // The draggable list is the connections plus the Foundry row, which rides along at its stored
  // index (`foundry.order`); FOUNDRY_ROW is its id in the order a reorder sends.
  const ids = connections.map((connection) => connection.id);
  if (foundry) ids.splice(Math.min(foundry.order ?? ids.length, ids.length), 0, FOUNDRY_ROW);
  const order = (next: string[]) => {
    if (next.join("\n") !== ids.join("\n")) void run({ action: "order", ids: next });
  };
  const rowDrag = (id: string, index: number): RowDrag => ({
    index,
    count: ids.length,
    busy,
    dragging: dragging === id,
    onDragStart: () => setDragging(id),
    onDragEnd: () => setDragging(null),
    onDrop: () => {
      if (dragging) order(moveId(ids, dragging, index));
      setDragging(null);
    },
    onMove: (to) => order(moveId(ids, id, to)),
  });
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
        {available && connections.length === 0 && !foundry && (
          <div className="row" data-empty="">
            <span className="row-help">{t("settingsWindow.models.personal.empty")}</span>
          </div>
        )}
        {ids.map((id, index) => {
          if (id === FOUNDRY_ROW) {
            return foundry ? (
              <FoundryRow key={id} foundry={foundry} available={available} drag={rowDrag(id, index)} />
            ) : null;
          }
          const connection = connections.find((c) => c.id === id);
          return connection ? (
            <ConnectionRow
              key={id}
              connection={connection}
              cloudCovered={cloudCovered(connections, connection)}
              run={run}
              drag={rowDrag(id, index)}
            />
          ) : null;
        })}
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

/** Microsoft Foundry in Your connections: its own connect/disconnect (not a route), no Cloud setup.
 * It reorders like a connection (its token rides in the stored order); `busy` is the list's ordering
 * gesture, separate from `running`, Foundry's own connect/region gesture. */
function FoundryRow({
  foundry,
  available,
  drag,
}: {
  foundry: NonNullable<ModelsState["foundry"]>;
  available: boolean;
  drag: RowDrag;
}) {
  const { index, count, busy, onMove } = drag;
  const nameId = useId();
  const { busy: running, error, detail, run } = useModelsRun();
  const [regionOpen, setRegionOpen] = useState(false);
  return (
    <div
      className="row models-connection"
      data-models-row="foundry"
      aria-busy={running || undefined}
      {...rowDrop(drag)}
    >
      <div className="row-main">
        <Grip id={FOUNDRY_ROW} drag={drag} />
        <span className="accounts-mark" aria-hidden="true">
          <FoundryMark />
        </span>
        <div className="row-label">
          <div className="row-title" id={nameId}>
            Microsoft Foundry
          </div>
          <div className="row-help" data-connection-auth={foundry.account ? "signedIn" : "signedOut"}>
            {foundry.account
              ? t("settingsWindow.harnesses.accounts.authenticatedAs", foundry.account)
              : t("settingsWindow.harnesses.notAuthenticated")}
          </div>
          <div className="row-help" data-connection-local="">
            {t("settingsWindow.models.thisMacOnly")}
          </div>
        </div>
        <div className="row-control">
          {running && <Spinner size={16} loading look="track" className="models-foundry-spinner" />}
          <Switch
            checked={foundry.enabled}
            disabled={!available || running}
            labelId={nameId}
            onToggle={(on) =>
              void run({
                action: "foundry",
                step: on ? "on" : "off",
                ...(foundry.region ? { region: foundry.region } : {}),
              })
            }
          />
          <Menu>
            <MenuButton
              className="button models-more"
              label={t("settingsWindow.models.more", "Microsoft Foundry")}
              data-menu="connection-foundry"
              disabled={running}
            >
              <Icon name="ellipsis" />
            </MenuButton>
            <MenuPopup align="end">
              <MenuItem data-value="moveUp" disabled={index === 0 || busy} onSelect={() => onMove(index - 1)}>
                {t("settingsWindow.models.moveUp")}
              </MenuItem>
              <MenuItem data-value="moveDown" disabled={index === count - 1 || busy} onSelect={() => onMove(index + 1)}>
                {t("settingsWindow.models.moveDown")}
              </MenuItem>
              <MenuItem data-value="switchRegion" disabled={!foundry.enabled} onSelect={() => setRegionOpen(true)}>
                {t("settingsWindow.models.foundry.switchRegion")}
              </MenuItem>
            </MenuPopup>
          </Menu>
        </div>
      </div>
      {regionOpen && <FoundryRegionDialog foundry={foundry} run={run} onClose={() => setRegionOpen(false)} />}
      {error && <RunError key={`${error}\0${detail ?? ""}`} summary={error} detail={detail} />}
    </div>
  );
}

/** A refused Models gesture: the short sentence, and an arrow that opens the host's own message.
 * Re-key on the text so a new failure starts closed. */
function RunError({ summary, detail }: { summary: string; detail: string | null }) {
  const [open, setOpen] = useState(false);
  const detailId = useId();
  return (
    <div className="models-run-error" data-models-error="" data-models-foundry-error="">
      <span className="models-grip" aria-hidden="true" />
      <div className="models-run-error-body">
        <div className="models-run-error-line">
          {detail && (
            <button
              type="button"
              className="models-run-error-toggle"
              aria-expanded={open}
              aria-controls={detailId}
              onClick={() => setOpen((shown) => !shown)}
            >
              <Icon name="chevron" />
            </button>
          )}
          <p className="row-error" role="alert">
            {summary}
          </p>
        </div>
        {open && detail && (
          <p className="models-run-error-detail" id={detailId}>
            {detail}
          </p>
        )}
      </div>
    </div>
  );
}

/** The daemon's region list, or just the current region when an older daemon omits it. */
function foundryRegions(foundry: { regions?: string[] | null; region?: string | null }): string[] {
  return foundry.regions ?? (foundry.region ? [foundry.region] : []);
}

/** Switch Region: a small dialog with the region list, not Add a Connection's setup screen. */
function FoundryRegionDialog({
  foundry,
  run,
  onClose,
}: {
  foundry: NonNullable<ModelsState["foundry"]>;
  run: Run;
  onClose(): void;
}) {
  const regions = foundryRegions(foundry);
  const regionId = useId();
  const current = foundry.region && regions.includes(foundry.region) ? foundry.region : regions[0];
  const [region, setRegion] = useState(current);
  const title = t("settingsWindow.models.foundry.switchRegion");
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
      label={title}
      className="ui-glass ui-glass-floats models-region"
    >
      <div className="models-region-body" data-models-region="">
        <DialogTitle>{title}</DialogTitle>
        <div className="row-title" id={regionId}>
          {t("settingsWindow.models.foundry.region")}
        </div>
        <Select value={region} disabled={false} labelId={regionId} closeOnPick onChange={setRegion}>
          {regions.map((option) => (
            <option key={option} value={option}>
              {option}
            </option>
          ))}
        </Select>
        <div className="accounts-buttons">
          <Button
            type="button"
            className="button"
            variant="solid"
            data-models-action="foundry.region"
            disabled={region === foundry.region}
            onClick={() => {
              onClose();
              void run({ action: "foundry", step: "region", region });
            }}
          >
            {t("settingsWindow.models.foundry.switch")}
          </Button>
        </div>
      </div>
    </Dialog>
  );
}

/** Microsoft Foundry's mark (acpmux writes the same PNG next to foundry.toml for the picker). */
function FoundryMark() {
  return (
    <img
      className="agent-mark agent-mark-image"
      src={foundryMark}
      width={16}
      height={16}
      alt=""
      draggable={false}
      style={{ display: "inline-flex", flex: "none", width: 16, height: 16, objectFit: "contain" }}
    />
  );
}

/** Foundry is a connection once OpenCode and az are here and az is signed in (or its harness is on);
 * until then Add a Connection > Cloud providers walks its setup. */
function foundryListed(foundry: ModelsState["foundry"]): boolean {
  if (!foundry) return false;
  if (foundry.enabled) return true;
  // Omitted means this daemon did not report the tool, not that it is missing.
  return foundry.az !== false && foundry.opencode !== false && !!foundry.account;
}

/** Whether another connection already serves Cloud for `connection`'s row (Settings > Cloud's rule): a
 * This Mac only login then needs no Set Up for Cloud link, since a Cloud chat already has what it uses. */
export function cloudCovered(connections: ModelConnection[], connection: ModelConnection): boolean {
  const row = cloudFocusOf(connection);
  return connections.some((c) => c.servesCloud && c.enabled && c.signedIn && cloudFocusOf(c) === row);
}

function ConnectionRow({
  connection,
  cloudCovered: covered,
  run,
  drag,
}: {
  connection: ModelConnection;
  cloudCovered: boolean;
  run: Run;
  drag: RowDrag;
}) {
  const { index, count, busy, onMove } = drag;
  const nameId = useId();
  const router = useSettingsRouter();
  const [confirming, setConfirming] = useState(false);
  const listed = useSettingsState().accounts?.signInAccounts;
  const store = useStore();
  // A finished sign-in reads Models again, so the row shows the login signed in.
  const signIn = useSettingsSignIn(() => void store.refreshModels());
  const builtin = connection.kind === "codex-login" || connection.kind === "claude-login";
  const plan = connection.kind === "chatgpt-plan";
  const reauth: ModelsRun | null = plan
    ? { action: "connectChatGPT", id: connection.id }
    : connection.kind === "claude-login"
      ? { action: "connectClaude" }
      : null;
  return (
    <div className="row models-connection" data-connection={connection.id} {...rowDrop(drag)}>
      <div className="row-main">
        <Grip id={connection.id} drag={drag} />
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
              {!covered && (
                <>
                  {" · "}
                  <Button
                    type="button"
                    variant="ghost"
                    size="sm"
                    className="link-button"
                    data-models-action="setUpForCloud"
                    onClick={() => router.history.push(sectionHref("cloud", cloudFocusOf(connection)))}
                  >
                    {t("settingsWindow.models.setUpForCloud")}
                  </Button>
                </>
              )}
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
                <MenuItem
                  data-value="signInAgain"
                  onSelect={() => {
                    if (reauth.action !== "connectClaude" || !signIn.inPlace) return void run(reauth);
                    // The CLI's own Claude login when it is signed out, else a new Claude account.
                    const own = (listed ?? [])
                      .flatMap((raw) => parseAccountRow(raw) ?? [])
                      .find((row) => row.family === "claude" && row.builtin);
                    signIn.begin("claude", own && !own.signedIn ? own.id : null, () => void run(reauth));
                  }}
                >
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
      {signIn.running && (
        <div className="harness-sign-in" data-connection-sign-in={connection.id}>
          <DeviceSignInCard family={signIn.running.family} view={signIn.running.view} look="inline" {...signIn.card} />
        </div>
      )}
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

/** Where Add a Connection opens: its list (null), or straight on one way in (Settings > Cloud's Set Up). */
export type SheetStart = "chatgpt" | "claude" | ModelProvider | null;

type Choice =
  | { kind: "chatgpt"; title: string; detail: string }
  | { kind: "claude"; title: string; detail: string }
  | { kind: "foundry"; title: string; detail: string }
  | { kind: "key"; provider: ModelProvider; title: string; detail: string };

const SUBSCRIPTIONS: Choice[] = [
  { kind: "chatgpt", title: "ChatGPT", detail: "chatgpt.com" },
  { kind: "claude", title: "Claude Code", detail: "claude.ai" },
];

const FOUNDRY: Choice = { kind: "foundry", title: "Microsoft Foundry", detail: "Azure CLI" };

const keyChoice = (provider: ModelProvider): Choice => ({
  kind: "key",
  provider,
  title: PROVIDERS[provider],
  detail: t("settingsWindow.models.sheet.apiKey"),
});

function startChoice(start: SheetStart): Choice | null {
  if (start === null) return null;
  return SUBSCRIPTIONS.find((choice) => choice.kind === start) ?? keyChoice(start as ModelProvider);
}

export function AddConnectionSheet({
  models,
  busy,
  run,
  onClose,
  start = null,
}: {
  models: ModelsState;
  busy: boolean;
  run: Run;
  onClose(): void;
  start?: SheetStart;
}) {
  const [query, setQuery] = useState("");
  const [picked, setPicked] = useState<Choice | null>(() => startChoice(start));
  const keys: Choice[] = KEY_PROVIDERS.map(keyChoice);
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
    {
      id: "cloud",
      title: t("settingsWindow.models.sheet.cloudProviders"),
      choices: models.foundry && !foundryListed(models.foundry) ? [FOUNDRY].filter(matches) : [],
    },
  ].filter((group) => group.choices.length > 0);
  // A ChatGPT sign-in that finishes with a new connection closes the sheet; Cancel or a failure keeps it.
  const { attempt, error } = models.chatgpt;
  const count = models.personal.connections.length;
  const before = useRef<number | null>(null);
  useEffect(() => {
    if (attempt) {
      if (before.current === null) before.current = count;
    } else if (before.current !== null) {
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
                        {choice.kind === "foundry" ? (
                          <FoundryMark />
                        ) : (
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
                        )}
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
        {picked?.kind === "foundry" && models.foundry && <FoundrySetup foundry={models.foundry} onDone={onClose} />}
        {picked?.kind === "key" && <KeyForm provider={picked.provider} busy={busy} run={run} onDone={onClose} />}
      </div>
    </Dialog>
  );
}

/** Add a Connection > Microsoft Foundry: circles 1–2–3, and only the active step under them.
 * Install runs OpenCode and the Azure CLI together; its bars read `foundry.install` while that run
 * is out. Enable closes the sheet. Switch Region is the row's dialog, not this sheet. */
function FoundrySetup({ foundry, onDone }: { foundry: NonNullable<ModelsState["foundry"]>; onDone(): void }) {
  const { busy, error, detail, run } = useModelsRun();
  const store = useStore();
  const regionId = useId();
  const [region, setRegion] = useState(foundry.region ?? "eastus2");
  const toolsReady = foundry.az !== false && foundry.opencode !== false;
  const signedIn = Boolean(foundry.az && foundry.account);
  const step = !toolsReady ? 1 : !signedIn ? 2 : 3;
  // Install takes minutes. The daemon publishes each tool's line on the Models state, which this
  // reads until the run returns.
  useEffect(() => {
    if (!busy || step !== 1) return;
    const pull = () => void store.refreshModels();
    pull();
    const id = setInterval(pull, 500);
    return () => clearInterval(id);
  }, [busy, step, store]);
  return (
    <div className="accounts-form" data-models-way="foundry">
      <ol className="models-foundry-steps">
        {[1, 2, 3].map((n) => (
          <li
            key={n}
            data-state={n < step ? "done" : n === step ? "current" : "todo"}
            aria-current={n === step ? "step" : undefined}
          >
            <span>{n}</span>
          </li>
        ))}
      </ol>
      {step === 1 && (
        <div data-models-foundry-step="install">
          <div className="row-title">{installTitle(foundry)}</div>
          <p className="row-help">{t("settingsWindow.models.foundry.installHelp")}</p>
          {busy ? (
            <div className="models-foundry-bars">
              {foundry.opencode === false && <InstallBar label="OpenCode" tool={foundry.install?.opencode} />}
              {foundry.az === false && <InstallBar label="Azure CLI" tool={foundry.install?.az} />}
            </div>
          ) : (
            <div className="accounts-buttons">
              <Button
                type="button"
                className="button"
                data-models-action="foundry.install"
                onClick={() => void run({ action: "foundry", step: "install" })}
              >
                {t("settingsWindow.agentIntegrations.install")}
              </Button>
            </div>
          )}
        </div>
      )}
      {step === 2 && (
        <div data-models-foundry-step="login">
          <div className="row-title">{t("settingsWindow.models.foundry.signIn")}</div>
          <p className="row-help">{t("settingsWindow.models.foundry.signInHelp")}</p>
          <div className="accounts-buttons">
            {busy ? (
              <Spinner size={16} loading look="track" />
            ) : (
              <Button
                type="button"
                className="button"
                data-models-action="foundry.login"
                onClick={() => void run({ action: "foundry", step: "login" })}
              >
                {t("settingsWindow.harnesses.signIn")}
              </Button>
            )}
          </div>
        </div>
      )}
      {step === 3 && (
        <div data-models-foundry-step="on">
          <p className="row-help">{t("settingsWindow.models.foundry.help")}</p>
          <div className="row-title" id={regionId}>
            {t("settingsWindow.models.foundry.region")}
          </div>
          {busy ? (
            <Spinner size={16} loading look="track" />
          ) : (
            <div className="accounts-buttons">
              <Select value={region} disabled={false} labelId={regionId} onChange={setRegion}>
                {foundryRegions(foundry).map((option) => (
                  <option key={option} value={option}>
                    {option}
                  </option>
                ))}
              </Select>
              <Button
                type="button"
                className="button"
                data-models-action="foundry.on"
                onClick={() => void run({ action: "foundry", step: "on", region }).then((ok) => ok && onDone())}
              >
                {t("settingsWindow.models.foundry.enable")}
              </Button>
            </div>
          )}
        </div>
      )}
      {error && <RunError key={`${error}\0${detail ?? ""}`} summary={error} detail={detail} />}
    </div>
  );
}

/** Both tools, or just the one that is missing. `az` / `opencode` omitted means unknown, not missing. */
function installTitle(foundry: NonNullable<ModelsState["foundry"]>): string {
  const opencode = foundry.opencode === false;
  const az = foundry.az === false;
  if (opencode && az) return t("settingsWindow.models.foundry.installBoth");
  return t("settingsWindow.models.foundry.installOne", opencode ? "OpenCode" : "Azure CLI");
}

/** The installer's phases, as a fill. It does not report bytes, so the bar steps through them. */
function installPercent(tool?: { state: string; detail: string }): number {
  if (!tool || tool.state === "error") return 0;
  if (tool.state === "done") return 100;
  if (tool.detail === "Downloaded") return 50;
  if (tool.detail.startsWith("Download")) return 25;
  if (tool.detail.startsWith("Install")) return 75;
  return 10;
}

/** One Install bar: a spinner and a percent while it runs, then the daemon's latest line. */
function InstallBar({ label, tool }: { label: string; tool?: { state: string; detail: string } }) {
  const done = tool?.state === "done";
  const percent = installPercent(tool);
  return (
    <div className="models-foundry-tool">
      <div className="models-foundry-tool-head">
        <div className="row-title">{label}</div>
        <span className="models-foundry-meter">
          {!done && <Spinner size={14} loading look="track" />}
          <span className="models-foundry-percent">{percent}%</span>
        </span>
      </div>
      <progress className="app-update-progress" aria-label={label} max={100} value={percent} />
      {tool?.detail && <p className="row-help">{tool.detail}</p>}
    </div>
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

/** Whether `token` reads as a Claude setup token; shared with the chat's model picker. */
export { isClaudeToken };

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
