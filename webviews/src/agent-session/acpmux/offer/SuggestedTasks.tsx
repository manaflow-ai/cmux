// An agent's suggested tasks in its chat (cx-lo9yf; one offer, cx-807da): the offers it made
// together draw as one card, "3 suggested tasks" with Start all, and each task offers Options, Do
// it here and Start; an offer made alone is the same card with one task. A started task becomes
// one quiet row hung off the card by an elbow, with what its chat is doing now, which opens that
// chat. The prompt that brings a task's result back draws as one "Received message from" line.
// A lone offer reads "New session" and its Options open the rows of Claude desktop's
// suggested-session card (OfferOptions.tsx): Environment, the folder, Worktree, Model, Effort and
// Permissions, each at the new chat's default until the person picks (offerChoice.ts).
// Gated by the `sessions.promptSuggestions` setting (or the Debug tunable forcing it on) or the
// session-offer experiment (offersShown.ts).
import { useId, useState } from "react";
import { Icon } from "../icons/Icon";
import { Bot } from "../conversation/icons";
import { useT, type Translate } from "../i18n";
import type { AcpmuxOfferResult, AcpmuxSessionOffer } from "../model";
import { errorMessage } from "../transportErrors";
import { ContextMenu } from "../../../ui/ContextMenu";
import "./suggestedTasks.css";
import { useTranscriptReadOnly } from "../conversation/readOnly";
import { openSessionAttributes } from "../conversation/menuParts";
import { OfferOptions } from "./OfferOptions";
import {
  initialChoice,
  pickIntent,
  useOfferDefaults,
  withPick,
  type OfferChoice,
  type OfferDefaults,
  type OfferGrant,
  type OfferPick,
  type OfferTickets,
} from "./offerChoice";

/// What a task's buttons do (App.tsx routes them to `chat.offer.*`).
export type OfferActions = {
  /// `tickets`: the gesture tickets of the choice's Effort and Permissions picks.
  start(offerId: string, choice: OfferChoice, tickets: OfferTickets): Promise<unknown>;
  /// Reserves the person's current gesture for one grant (`transport.gesture`); unset where the
  /// page has no host to ask.
  reserve?(intent: OfferGrant): Promise<string | undefined>;
  here(offerId: string): Promise<unknown>;
  dismiss(offerId: string): Promise<unknown>;
  open(childSessionId: string): void;
};

type Busy = "start" | "here" | "dismiss";

/// A pick's ticket, and when its gesture was: the host keeps a ticket a minute
/// (`AgentPaneUserGestures.ticketLifetime`), so Start takes a new one for an older pick.
type Held = { ticket: Promise<string | undefined>; at: number };
const FRESH_MS = 45_000;

export function SuggestedTasks({ offers, actions }: { offers: AcpmuxSessionOffer[]; actions: OfferActions }) {
  const t = useT();
  const [busy, setBusy] = useState<Record<string, Busy>>({});
  const [errors, setErrors] = useState<Record<string, string>>({});
  const defaults = useOfferDefaults();
  // Each task's Options, from the agent's ask until the person changes them, and the gesture
  // tickets of its grants.
  const [choices, setChoices] = useState<Record<string, OfferChoice>>({});
  const [held, setHeld] = useState<Record<string, { mode?: Held; effort?: Held }>>({});
  const choice = (offer: AcpmuxSessionOffer) => choices[offer.offerId] ?? initialChoice(offer);
  const reserve = (intent: OfferGrant): Held => ({
    ticket: actions.reserve?.(intent).catch(() => undefined) ?? Promise.resolve(undefined),
    at: Date.now(),
  });
  // A pick from this chat's lists; an Effort or Permissions pick takes its ticket on this click.
  const pick = (offer: AcpmuxSessionOffer, part: OfferPick) => {
    if (!defaults) return;
    setChoices((current) => ({ ...current, [offer.offerId]: withPick(choice(offer), offer, defaults, part) }));
    const grant = part.mode ? { mode: reserve(pickIntent({ mode: part.mode })) } : {};
    const effort = part.effort ? { effort: reserve(pickIntent({ effort: part.effort })) } : {};
    setHeld((current) => ({ ...current, [offer.offerId]: { ...current[offer.offerId], ...grant, ...effort } }));
  };
  // Start's tickets: each pick's own, or one taken by this click for a pick older than a ticket lives.
  const tickets = (offer: AcpmuxSessionOffer, picked: OfferChoice): OfferTickets => {
    const fresh = (kept: Held | undefined, intent: OfferGrant) =>
      kept && Date.now() - kept.at < FRESH_MS ? kept.ticket : reserve(intent).ticket;
    const kept = held[offer.offerId];
    return {
      ...(picked.mode ? { mode: fresh(kept?.mode, pickIntent({ mode: picked.mode })) } : {}),
      ...(picked.effort ? { effort: fresh(kept?.effort, pickIntent({ effort: picked.effort })) } : {}),
    };
  };
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
  const start = (offer: AcpmuxSessionOffer) => {
    const picked = choice(offer);
    const granted = tickets(offer, picked);
    return run(offer.offerId, "start", () => actions.start(offer.offerId, picked, granted));
  };
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
            defaults={defaults}
            choice={choice(offer)}
            onChoice={(next) => setChoices((current) => ({ ...current, [offer.offerId]: next }))}
            onPick={(part) => pick(offer, part)}
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

/// "3 suggested tasks", or a lone offer's "New session".
function heading(t: Translate, offers: AcpmuxSessionOffer[], single: boolean): string {
  return single ? t("offer.newSession") : t("offer.tasks.count", { n: offers.length });
}

function OpenTask({
  offer,
  busy,
  error,
  defaults,
  choice,
  onChoice,
  onPick,
  onStart,
  onHere,
  onDismiss,
}: {
  offer: AcpmuxSessionOffer;
  busy?: Busy;
  error?: string;
  defaults: OfferDefaults | undefined;
  choice: OfferChoice;
  onChoice(next: OfferChoice): void;
  onPick(pick: OfferPick): void;
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
          <OfferOptions
            offer={offer}
            defaults={defaults}
            choice={choice}
            disabled={off}
            onChoice={onChoice}
            onPick={onPick}
            onDismiss={onDismiss}
          />
          {choice.worktree && <span className="acpmux-task-note">{t("offer.worktree")}</span>}
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
        {...(readOnly
          ? {}
          : {
              type: "button" as const,
              onClick: () => onOpen(result.childSessionId),
              ...openSessionAttributes(result.childSessionId),
            })}
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
