// An agent's suggested tasks in its chat (cx-lo9yf; one offer, cx-807da): the offers it made
// together draw as one card, "3 suggested tasks" with Start all, and each task offers Options, Do
// it here and Start; an offer made alone is the same card with one task. A started task becomes
// one quiet row hung off the card by an elbow, with what its chat is doing now, which opens that
// chat. The prompt that brings a task's result back draws as one "Received message from" line.
// Gated by the `sessions.promptSuggestions` setting (or the Debug tunable forcing it on) or the
// session-offer experiment (offersShown.ts).
import { useId, useState } from "react";
import { Icon } from "../icons/Icon";
import { Bot } from "../conversation/icons";
import { useT, type Translate } from "../i18n";
import type { AcpmuxOfferResult, AcpmuxSessionOffer } from "../model";
import { errorMessage } from "../transportErrors";
import { ContextMenu } from "../../../ui/ContextMenu";
import { Menu, MenuButton, MenuCheckboxItem, MenuItem, MenuPopup } from "../../../ui/Menu";
import "./suggestedTasks.css";
import { useTranscriptReadOnly } from "../conversation/readOnly";

/// What a task's buttons do (App.tsx routes them to `chat.offer.*`).
export type OfferActions = {
  start(offerId: string, worktree: boolean): Promise<unknown>;
  here(offerId: string): Promise<unknown>;
  dismiss(offerId: string): Promise<unknown>;
  open(childSessionId: string): void;
};

type Busy = "start" | "here" | "dismiss";

export function SuggestedTasks({ offers, actions }: { offers: AcpmuxSessionOffer[]; actions: OfferActions }) {
  const t = useT();
  const [busy, setBusy] = useState<Record<string, Busy>>({});
  const [errors, setErrors] = useState<Record<string, string>>({});
  // Each task's Options > Start in a new worktree, from the agent's ask until the person changes it.
  const [worktrees, setWorktrees] = useState<Record<string, boolean>>({});
  const worktree = (offer: AcpmuxSessionOffer) => worktrees[offer.offerId] ?? offer.worktree;
  const open = offers.filter((offer) => !offer.outcome);
  const started = offers.filter((offer) => offer.outcome === "accepted" && offer.childSessionId);
  const single = offers.length === 1 && !offers[0]!.groupId;
  if (open.length === 0 && started.length === 0) return null;

  const mark = (offerId: string, which: Busy | undefined, error?: string) => {
    setBusy((current) => withKey(current, offerId, which));
    setErrors((current) => withKey(current, offerId, error));
  };
  // Busy until acpmux's decision record answers the task, so its buttons never come back between.
  const run = async (offerId: string, which: Busy, action: () => Promise<unknown>) => {
    mark(offerId, which);
    try {
      await action();
    } catch (failure) {
      mark(offerId, undefined, errorMessage(failure) || t("offer.failed"));
    }
  };
  const start = (offer: AcpmuxSessionOffer) =>
    run(offer.offerId, "start", () => actions.start(offer.offerId, worktree(offer)));
  const here = (offer: AcpmuxSessionOffer) => void run(offer.offerId, "here", () => actions.here(offer.offerId));
  const dismiss = (offer: AcpmuxSessionOffer) =>
    void run(offer.offerId, "dismiss", () => actions.dismiss(offer.offerId));
  // Start all starts the open tasks in the order the agent gave them, one after another.
  const startAll = async () => {
    const waiting = open.filter((offer) => !busy[offer.offerId]);
    for (const offer of waiting) mark(offer.offerId, "start");
    for (const offer of waiting) await start(offer);
  };

  // A lone task once started is its row alone, with no card around it.
  const quiet = single && open.length === 0;
  return (
    <section className="acpmux-tasks" data-quiet={quiet || undefined} aria-label={heading(t, offers, single)}>
      {!quiet && (
        <div className="acpmux-tasks-head">
          <span className="acpmux-tasks-count">{heading(t, offers, single)}</span>
          {!single && open.length === 0 && (
            <span className="acpmux-tasks-note">{t("offer.tasks.started", { n: started.length })}</span>
          )}
          {open.length >= 2 && (
            <button
              type="button"
              className="acpmux-task-action acpmux-tasks-all"
              disabled={open.every((offer) => busy[offer.offerId])}
              onClick={() => void startAll()}
            >
              {t("offer.tasks.startAll")}
            </button>
          )}
        </div>
      )}
      {offers.map((offer) =>
        !offer.outcome ? (
          <OpenTask
            key={offer.offerId}
            offer={offer}
            busy={busy[offer.offerId]}
            error={errors[offer.offerId]}
            worktree={worktree(offer)}
            onWorktree={(on) => setWorktrees((current) => ({ ...current, [offer.offerId]: on }))}
            onStart={() => void start(offer)}
            onHere={() => here(offer)}
            onDismiss={() => dismiss(offer)}
          />
        ) : offer.outcome === "accepted" && offer.childSessionId ? (
          <StartedTask key={offer.offerId} offer={offer} child={offer.childSessionId} onOpen={actions.open} />
        ) : null,
      )}
    </section>
  );
}

/// `record` with `key` set to `value`, or without `key` when `value` is undefined.
function withKey<T>(record: Record<string, T>, key: string, value: T | undefined): Record<string, T> {
  const next = { ...record };
  if (value === undefined) delete next[key];
  else next[key] = value;
  return next;
}

/// "3 suggested tasks", or a lone offer's "Suggested".
function heading(t: Translate, offers: AcpmuxSessionOffer[], single: boolean): string {
  return single ? t("offer.label") : t("offer.tasks.count", { n: offers.length });
}

function OpenTask({
  offer,
  busy,
  error,
  worktree,
  onWorktree,
  onStart,
  onHere,
  onDismiss,
}: {
  offer: AcpmuxSessionOffer;
  busy?: Busy;
  error?: string;
  worktree: boolean;
  onWorktree(on: boolean): void;
  onStart(): void;
  onHere(): void;
  onDismiss(): void;
}) {
  const t = useT();
  const titleId = useId();
  const off = busy !== undefined;
  const items = [
    { id: "start", label: t("offer.start"), disabled: off, onSelect: onStart },
    { id: "here", label: t("offer.here"), disabled: off, onSelect: onHere },
    { id: "dismiss", label: t("offer.dismiss"), disabled: off, separatorBefore: true, onSelect: onDismiss },
  ];
  return (
    <ContextMenu items={items} targets="own">
      <div className="acpmux-task" data-busy={busy}>
        <div className="acpmux-task-head">
          <span className="acpmux-task-title" id={titleId}>
            {offer.title}
          </span>
          <button
            type="button"
            className="acpmux-task-dismiss"
            aria-label={t("offer.dismiss")}
            aria-describedby={titleId}
            disabled={off}
            onClick={onDismiss}
          >
            <Icon name="action.close" size={12} />
          </button>
        </div>
        <p className="acpmux-task-prompt">{offer.prompt}</p>
        {error && (
          <span className="acpmux-task-error" role="alert">
            {error}
          </span>
        )}
        <div className="acpmux-task-actions" aria-live="polite">
          <Menu>
            <MenuButton className="acpmux-task-action" aria-haspopup="menu" disabled={off}>
              {t("offer.options")}
            </MenuButton>
            <MenuPopup className="ui-context-menu acpmux-task-menu" label={t("offer.options")} align="start">
              <MenuCheckboxItem checked={worktree} onCheckedChange={onWorktree}>
                {t("offer.newWorktree")}
              </MenuCheckboxItem>
              <MenuItem onSelect={onDismiss}>{t("offer.dismiss")}</MenuItem>
            </MenuPopup>
          </Menu>
          {worktree && <span className="acpmux-task-note">{t("offer.worktree")}</span>}
          <span className="acpmux-task-spacer" />
          {busy === "start" ? (
            <span className="acpmux-task-note">{t("offer.starting")}</span>
          ) : (
            <>
              <button
                type="button"
                className="acpmux-task-action"
                aria-describedby={titleId}
                disabled={off}
                onClick={onHere}
              >
                {t("offer.here")}
              </button>
              <button
                type="button"
                className="acpmux-task-action"
                data-primary
                aria-describedby={titleId}
                disabled={off}
                onClick={onStart}
              >
                {t("offer.start")}
              </button>
            </>
          )}
        </div>
      </div>
    </ContextMenu>
  );
}

/// What a started task's chat is doing: its latest tool call while it runs, else its state.
function childState(offer: AcpmuxSessionOffer): "running" | "waiting" | "failed" | "done" | "started" {
  const status = offer.childStatus;
  if (status === undefined) return "started";
  if (status === "running" || status === "waiting" || status === "failed") return status;
  return "done";
}

function subtitle(t: Translate, offer: AcpmuxSessionOffer): string {
  const state = childState(offer);
  if (state === "running") return offer.activity ?? t("subagents.state.running");
  if (state === "waiting") return t("home.needsInput");
  if (state === "failed") return t("subagents.state.failed");
  if (state === "done") return t("subagents.state.completed");
  return offer.activity ?? t("offer.started");
}

/// A started task: `⎿ title  what it does now  •  ›`; a click opens its chat.
function StartedTask({
  offer,
  child,
  onOpen,
}: {
  offer: AcpmuxSessionOffer;
  child: string;
  onOpen(childSessionId: string): void;
}) {
  const t = useT();
  const items = [{ id: "open", label: t("subagents.open", { name: offer.title }), onSelect: () => onOpen(child) }];
  return (
    <ContextMenu items={items} targets="own">
      <div className="acpmux-task-started" data-state={childState(offer)}>
        <button
          type="button"
          className="acpmux-task-row"
          aria-label={t("subagents.open", { name: offer.title })}
          onClick={() => onOpen(child)}
        >
          <span className="acpmux-task-elbow" aria-hidden="true">
            ⎿
          </span>
          <span className="acpmux-task-row-title">{offer.title}</span>
          <span className="acpmux-task-row-sub">{subtitle(t, offer)}</span>
          <span className="acpmux-task-dot" aria-hidden="true" />
          <Icon name="disclosure.collapsed" size={12} />
        </button>
      </div>
    </ContextMenu>
  );
}

/// The prompt that brought a started task's result back: "Received message from <title> ›",
/// which opens that task's chat. It draws as another agent's message line does
/// (conversation/IncomingMessageCard.tsx): at the left with the agent's text, never the person's
/// bubble, a small bot first and the task's title as a chip. The title keeps its place in the
/// sentence in every language.
export function ReceivedResult({
  result,
  onOpen,
}: {
  result: AcpmuxOfferResult;
  onOpen(childSessionId: string): void;
}) {
  const t = useT();
  // Read only, the line says what came back; the chat it came from is the owner's to open.
  const readOnly = useTranscriptReadOnly();
  const [before, after = ""] = t("offer.received", { title: "\u0000" }).split("\u0000");
  const Line = readOnly ? "div" : "button";
  return (
    <div className="acpmux-task-received">
      <Line
        {...(readOnly ? {} : { type: "button" as const, onClick: () => onOpen(result.childSessionId) })}
        className="acpmux-task-received-line"
      >
        <span className="acpmux-task-received-icon">
          <Bot size={16} />
        </span>
        {before}
        <span className="acpmux-task-received-title">{result.title}</span>
        {after}
        <Icon name="disclosure.collapsed" size={12} />
      </Line>
    </div>
  );
}
