// The chat header's Needs you badge and its pinned list (Leo 2026-10-20), shaped like Discord's
// pinned messages: a count in the header, and a press opens every open ask in one list. Each ask
// says who asked and how long ago, answers in one click when the answer is simple (Allow, Deny, one
// of its choices), jumps to where it was asked (Go to source) and can be asked about in a side
// question seeded with the ask (Ask about this), so nobody re-reads a thread to answer it. An ask
// leaves the list once acpmux says it was answered, wherever that was (asks.ts).
//
// A row has stages (Leo 2026-10-21: "THERE'S MULTIPLE STATES WHERE YOU CAN MAYBE EXPAND, ANSWER
// INLINE AND MAYBE EXPAND FURTHER FOR THE CONTEXT AND MAYBE JUMP TO THAT WORKSPACE... OR OPEN NEW
// WORKSPACE... OR OPEN ON RIGHT"): the one-line card; expanded, with the whole ask, every option
// and a typed answer for a question, and the ways to open its chat (on the right, the default; the
// workspace that shows it; a new workspace); and its context, the last turns before the ask.
import { useEffect, useRef, useState, type RefObject } from "react";
import { AgentMark } from "../../shared/AgentMark";
import { useMinuteClock } from "../clock";
import { agentDisplayName } from "../agents";
import { HEADER_GLYPH } from "../header/ChatHeaderTools";
import { HeaderIcon } from "../header/HeaderIcon";
import { useT, type StringKey, type Translate } from "../i18n";
import { Icon } from "../icons/Icon";
import { shortAge } from "../sessionList";
import { Popover } from "../../../ui/Popover";
import { usePopoverTrigger } from "../../../ui/popoverTrigger";
import { onOpenNeedsYou } from "./links";
import type { NeedsYouAnswer, NeedsYouItem, NeedsYouKind } from "./model";
import type { AskContext } from "./context";
import { reply as questionReply, selection, type AgentQuestion, type QuestionReply } from "../question/model";
import { messagePreview } from "../conversation/incomingMessage";
import "./needsYou.css";

/// The Debug choice `agentPane.debug.needsYou` (data-needs-you on <html>): `pinned` (the default)
/// draws each ask with its answers; `compact` one line per ask; `off` no badge at all. The host
/// also writes `off` while the App Store's Needs You item is not installed
/// (`agentPane.needsYou.enabled`, off by default): no badge, no list, and no link opens one.
export type NeedsYouMode = "pinned" | "compact" | "off";

export function needsYouMode(
  root: { dataset: DOMStringMap } | undefined = globalThis.document?.documentElement,
): NeedsYouMode {
  const value = root?.dataset.needsYou;
  return value === "off" || value === "compact" ? value : "pinned";
}

export type NeedsYouActions = {
  /// Sends a one-click answer; rejects when acpmux refused it.
  answer(item: NeedsYouItem, answer: NeedsYouAnswer): Promise<unknown>;
  /// Opens the chat the ask is in, at the ask.
  goTo(item: NeedsYouItem): void;
  /// Opens a side session about the asking chat (`_acpmux/btw`) beside it, its first prompt the
  /// question seeded with the ask; rejects when it could not.
  ask(item: NeedsYouItem, question: string): Promise<unknown>;
  /// Sends an expanded question's whole answer (every item, an Other text); rejects when it was
  /// refused or could not be sent from here (another chat's question opens that chat instead).
  reply?(item: NeedsYouItem, sent: QuestionReply): Promise<unknown>;
  /// The turns before the ask, for the context stage (context.ts).
  context?(item: NeedsYouItem): AskContext;
  /// Opens another chat's ask at `place`: on the right (the default, as Go to source), the
  /// workspace whose tab shows it, or a new workspace (`chat.asks.open {where}`).
  open?(item: NeedsYouItem, place: NeedsYouPlace): void;
  /// Whether `open` can open the ask's chat: another chat on this pane's own acpmux, never the chat
  /// on screen (its ask is already here) or another computer's.
  opensElsewhere?(item: NeedsYouItem): boolean;
};

/// Where the expanded row opens another chat: `right` (the default), `workspace` (jump to the tab
/// that shows the chat, in whatever workspace or window), `newWorkspace`.
export type NeedsYouPlace = "right" | "workspace" | "newWorkspace";

const PLACES: readonly { place: NeedsYouPlace; label: StringKey }[] = [
  { place: "right", label: "needsYou.openRight" },
  { place: "workspace", label: "needsYou.jumpToWorkspace" },
  { place: "newWorkspace", label: "needsYou.openNewWorkspace" },
];

const KINDS: Record<NeedsYouKind, StringKey> = {
  approval: "needsYou.kind.approval",
  decision: "needsYou.kind.decision",
  verify: "needsYou.kind.verify",
  held: "needsYou.kind.held",
  input: "needsYou.kind.input",
  tab: "needsYou.kind.tab",
};

const CHIEF_AVATAR = new URL("../mascots/ChiefMascotOrb.png", import.meta.url).href;

/// The header's badge: the count of open asks; a press opens the list.
export function NeedsYouButton({
  items,
  mode = "pinned",
  actions,
  defaultOpen = false,
}: {
  items: readonly NeedsYouItem[];
  mode?: NeedsYouMode;
  actions: NeedsYouActions;
  defaultOpen?: boolean;
}) {
  const t = useT();
  const [open, setOpen] = useState(defaultOpen);
  const [focus, setFocus] = useState<string>();
  const [button, setButton] = useState<HTMLButtonElement | null>(null);
  const buttonRef = useRef<HTMLButtonElement | null>(null);
  // The list takes focus on open, not its first row's Go to source: a ring on that arrow read as a
  // bordered button (Leo 2026-10-21). Tab still reaches every row's tools from here.
  const panelRef = useRef<HTMLDivElement | null>(null);
  const trigger = usePopoverTrigger(open, setOpen);
  // A `cmux://needs-you/<id>` chip in a reply opens the list on its ask (links.ts). Off (the App
  // Store item not installed) registers no opener, so nothing can open a list that is not drawn.
  useEffect(
    () =>
      mode === "off"
        ? undefined
        : onOpenNeedsYou((itemId) => {
            setFocus(itemId);
            setOpen(true);
          }),
    [mode],
  );
  if (mode === "off") return null;
  const count = items.length;
  const label = count > 0 ? t("needsYou.badgeLabel", { n: count }) : t("needsYou.title");
  return (
    <>
      <button
        ref={(element) => {
          buttonRef.current = element;
          setButton(element);
        }}
        type="button"
        className="acpmux-header-tool acpmux-needs-you-button"
        data-count={count > 0 ? "" : undefined}
        aria-label={label}
        // A tooltip only names an icon-only control (test/tooltip-rules.ts): with asks open the
        // count shows, so the button keeps just its aria-label; with none it is the inbox icon alone.
        {...(count > 0 ? {} : { title: label })}
        aria-haspopup="dialog"
        aria-expanded={open}
        {...trigger}
      >
        <HeaderIcon name="inbox" size={HEADER_GLYPH} />
        {count > 0 && (
          <span className="acpmux-needs-you-count">
            <span className="acpmux-needs-you-dot" aria-hidden="true" />
            {count > 99 ? "99+" : count}
          </span>
        )}
      </button>
      <Popover
        open={open}
        onOpenChange={(next) => {
          if (!next) {
            setOpen(false);
            setFocus(undefined);
          }
        }}
        anchor={button}
        label={t("needsYou.title")}
        className="acpmux-needs-you"
        side="bottom"
        initialFocus={panelRef}
        finalFocus={buttonRef}
      >
        <NeedsYouPanel
          panelRef={panelRef}
          items={items}
          mode={mode}
          actions={{
            ...actions,
            goTo: (item) => {
              setOpen(false);
              actions.goTo(item);
            },
            ...(actions.open
              ? {
                  open: (item: NeedsYouItem, place: NeedsYouPlace) => {
                    setOpen(false);
                    actions.open?.(item, place);
                  },
                }
              : {}),
          }}
          focus={focus}
        />
      </Popover>
    </>
  );
}

/// The list itself: a title with the count, then each ask, newest first.
export function NeedsYouPanel({
  items,
  mode = "pinned",
  actions,
  focus,
  panelRef,
}: {
  items: readonly NeedsYouItem[];
  mode?: NeedsYouMode;
  actions: NeedsYouActions;
  /// The ask a link opened the list on: scrolled to and marked.
  focus?: string;
  /// The popover's initial focus target.
  panelRef?: RefObject<HTMLDivElement | null>;
}) {
  const t = useT();
  const now = useMinuteClock();
  // Asks answered here, hidden until acpmux's change takes them off the list.
  const [sent, setSent] = useState<ReadonlySet<string>>(new Set());
  const shown = items.filter((item) => !sent.has(item.id));
  const missing = focus !== undefined && !items.some((item) => item.id === focus);
  return (
    <div ref={panelRef} className="acpmux-needs-you-panel" data-mode={mode} tabIndex={-1}>
      <header className="acpmux-needs-you-head">
        <span className="acpmux-needs-you-title">{t("needsYou.title")}</span>
        {shown.length > 0 && <span className="acpmux-needs-you-total">{shown.length}</span>}
      </header>
      {missing && <p className="acpmux-needs-you-note">{t("needsYou.gone")}</p>}
      {shown.length === 0 ? (
        <div className="acpmux-needs-you-empty">
          <Icon name="inbox.empty" size={20} />
          <span>{t("needsYou.empty")}</span>
        </div>
      ) : (
        <ul className="acpmux-needs-you-list">
          {shown.map((item) => (
            <NeedsYouRow
              key={item.id}
              item={item}
              mode={mode}
              now={now}
              focused={item.id === focus}
              actions={actions}
              onSent={() => setSent((before) => new Set(before).add(item.id))}
              onRefused={() =>
                setSent((before) => {
                  const next = new Set(before);
                  next.delete(item.id);
                  return next;
                })
              }
            />
          ))}
        </ul>
      )}
    </div>
  );
}

function NeedsYouRow({
  item,
  mode,
  now,
  focused,
  actions,
  onSent,
  onRefused,
}: {
  item: NeedsYouItem;
  mode: NeedsYouMode;
  now: number;
  focused: boolean;
  actions: NeedsYouActions;
  onSent(): void;
  onRefused(): void;
}) {
  const t = useT();
  const row = useRef<HTMLLIElement>(null);
  const [failed, setFailed] = useState(false);
  const [sending, setSending] = useState<string>();
  const [asking, setAsking] = useState(false);
  // The row's stage: the one-line card, expanded, or expanded with its context.
  const [stage, setStage] = useState<"row" | "expanded" | "context">("row");
  const expanded = stage !== "row";
  useEffect(() => {
    if (focused) row.current?.scrollIntoView({ block: "nearest" });
  }, [focused]);
  const answer = (choice: NeedsYouAnswer) => {
    // Review opens a guest's held message on its card, where the owner reads it whole and answers.
    if (choice.id === "review") {
      actions.goTo(item);
      return;
    }
    if (sending) return;
    setSending(choice.id);
    setFailed(false);
    actions.answer(item, choice).then(onSent, () => {
      setSending(undefined);
      setFailed(true);
      onRefused();
    });
  };
  const compact = mode === "compact" && !expanded;
  const age = shortAge(item.at, now, t);
  // An expanded question takes its whole answer in the form; the one-click row is for the card.
  const form = expanded && item.question && item.permissionId && actions.reply ? item.question : undefined;
  const toggle = () => setStage((now) => (now === "row" ? "expanded" : "row"));
  return (
    <li
      ref={row}
      className="acpmux-needs-you-item"
      data-kind={item.kind}
      data-focused={focused ? "" : undefined}
      data-stage={stage === "row" ? undefined : stage}
    >
      <div className="acpmux-needs-you-meta">
        <Avatar item={item} />
        <span className="acpmux-needs-you-who">{item.who.chief ? t("needsYou.chief") : item.who.name}</span>
        {item.who.via && <span className="acpmux-needs-you-via">{t("needsYou.via", { name: item.who.via })}</span>}
        <span className="acpmux-needs-you-kind">{t(KINDS[item.kind])}</span>
        {/* The row's end: its age at rest; on hover or keyboard focus, its tools in the same slot,
            plain icons with no chrome of their own (Leo 2026-10-21). */}
        <span className="acpmux-needs-you-end">
          {age && <span className="acpmux-needs-you-age">{age}</span>}
          <span className="acpmux-needs-you-tools">
            {/* A marked tab names no chat to ask about or open elsewhere: Go to is its one action. */}
            {item.kind !== "tab" && (
              <button
                type="button"
                className="acpmux-needs-you-expand"
                aria-label={expanded ? t("needsYou.collapse") : t("needsYou.expand")}
                title={expanded ? t("needsYou.collapse") : t("needsYou.expand")}
                aria-expanded={expanded}
                onClick={toggle}
              >
                <Icon name={expanded ? "disclosure.expanded" : "disclosure.collapsed"} size={14} />
              </button>
            )}
            {!compact && item.kind !== "tab" && (
              <button
                type="button"
                className="acpmux-needs-you-ask-about"
                aria-label={t("needsYou.askAbout")}
                title={t("needsYou.askAbout")}
                aria-expanded={asking}
                onClick={() => setAsking((open) => !open)}
              >
                <Icon name="agent.question" size={14} />
              </button>
            )}
            <button
              type="button"
              className="acpmux-needs-you-go"
              aria-label={t("needsYou.goToSource")}
              title={t("needsYou.goToSource")}
              onClick={() => actions.goTo(item)}
            >
              <Icon name="action.go" size={14} />
            </button>
          </span>
        </span>
      </div>
      {/* The ask itself expands the row too: the person reads it and wants the rest. */}
      <p className="acpmux-needs-you-ask">
        {/* A marked tab's reason goes to the tab: it has no chat to expand. */}
        <button
          type="button"
          className="acpmux-needs-you-ask-toggle"
          aria-expanded={item.kind === "tab" ? undefined : expanded}
          onClick={item.kind === "tab" ? () => actions.goTo(item) : toggle}
        >
          {askText(item, t)}
        </button>
      </p>
      {!compact && item.detail && (
        <p className="acpmux-needs-you-detail" data-code={item.command ? "" : undefined}>
          {item.detail}
        </p>
      )}
      {form && (
        <QuestionForm
          question={form}
          send={(sent) => actions.reply!(item, sent)}
          onSent={onSent}
          onRefused={onRefused}
        />
      )}
      {!compact && !form && item.answers.length > 0 && (
        <div className="acpmux-needs-you-actions">
          {/* Claude's permission card: the answers as numbered rows, the first one ready. */}
          <fieldset className="acpmux-needs-you-options" aria-label={askText(item, t)}>
            {item.answers.map((choice) => (
              <button
                key={choice.id}
                type="button"
                className="acpmux-needs-you-answer"
                data-tone={choice.tone}
                disabled={sending !== undefined}
                aria-busy={sending === choice.id}
                onClick={() => answer(choice)}
              >
                <span className="acpmux-needs-you-answer-label">
                  {item.kind !== "held"
                    ? choice.label
                    : item.promptId
                      ? t("queue.held.review")
                      : choice.id === "resume"
                        ? t("needsYou.resume")
                        : choice.label}
                </span>
              </button>
            ))}
          </fieldset>
        </div>
      )}
      {failed && <p className="acpmux-needs-you-error">{t("needsYou.answerFailed")}</p>}
      {expanded && (
        <div className="acpmux-needs-you-more">
          {actions.context && (
            <button
              type="button"
              className="acpmux-needs-you-more-button"
              aria-expanded={stage === "context"}
              onClick={() => setStage((now) => (now === "context" ? "expanded" : "context"))}
            >
              {stage === "context" ? t("needsYou.contextHide") : t("needsYou.context")}
            </button>
          )}
          {/* Another chat opens where the person picks; this chat's ask is already on screen. */}
          {actions.open &&
            actions.opensElsewhere?.(item) &&
            PLACES.map(({ place, label }) => (
              <button
                key={place}
                type="button"
                className="acpmux-needs-you-more-button"
                data-place={place}
                onClick={() => actions.open?.(item, place)}
              >
                {t(label)}
              </button>
            ))}
        </div>
      )}
      {stage === "context" && actions.context && <AskContextTurns item={item} context={actions.context(item)} />}
      {asking && !compact && <SideQuestion item={item} ask={actions.ask} onAsked={() => setAsking(false)} />}
    </li>
  );
}

/// The context stage: the last turns before the ask, read-only, oldest first. Another chat's is
/// only its latest message, and says so.
function AskContextTurns({ item, context }: { item: NeedsYouItem; context: AskContext }) {
  const t = useT();
  const agent = item.who.chief ? t("needsYou.chief") : item.who.name;
  return (
    <div className="acpmux-needs-you-context" aria-label={t("needsYou.context")}>
      {context.turns.length === 0 ? (
        <p className="acpmux-needs-you-context-note">{t("needsYou.contextEmpty")}</p>
      ) : (
        <ol className="acpmux-needs-you-context-turns">
          {context.turns.map((turn) => (
            <li key={turn.id} className="acpmux-needs-you-context-turn" data-who={turn.who}>
              <span className="acpmux-needs-you-context-who">
                {turn.who === "person" ? t("needsYou.contextYou") : agent}
              </span>
              <span className="acpmux-needs-you-context-text">{turn.text}</span>
            </li>
          ))}
        </ol>
      )}
      {context.partial && <p className="acpmux-needs-you-context-note">{t("needsYou.contextPartial")}</p>}
    </div>
  );
}

/// An expanded question: every item with all its options (radio or checkbox), an Other field where
/// the ask takes typed text, and Submit, which sends the whole answer in the harness's shape
/// (question/model.ts `reply`). A click picks and never sends, as the ask's card (QuestionCard).
function QuestionForm({
  question,
  send,
  onSent,
  onRefused,
}: {
  question: AgentQuestion;
  send(sent: QuestionReply): Promise<unknown>;
  onSent(): void;
  onRefused(): void;
}) {
  const t = useT();
  const [picks, setPicks] = useState<Readonly<Record<string, readonly string[]>>>({});
  const [other, setOther] = useState<Readonly<Record<string, string>>>({});
  const [busy, setBusy] = useState(false);
  const [failed, setFailed] = useState(false);
  const answered = (id: string) => (picks[id]?.length ?? 0) > 0 || Boolean(other[id]?.trim());
  const ready = question.items.every((item) => answered(item.id));
  const pick = (itemId: string, optionId: string, multi: boolean) => {
    setPicks((before) => {
      const now = before[itemId] ?? [];
      const next = multi
        ? now.includes(optionId)
          ? now.filter((id) => id !== optionId)
          : [...now, optionId]
        : [optionId];
      return { ...before, [itemId]: next };
    });
    // One answer to a single choice: a picked option replaces typed text.
    if (!multi) setOther((before) => ({ ...before, [itemId]: "" }));
  };
  const type = (itemId: string, text: string, multi: boolean) => {
    setOther((before) => ({ ...before, [itemId]: text }));
    if (!multi && text.trim()) setPicks((before) => ({ ...before, [itemId]: [] }));
  };
  const submit = () => {
    if (busy || !ready) return;
    let sent: QuestionReply;
    try {
      sent = questionReply(question, {
        selections: Object.fromEntries(
          question.items.map((item) => {
            const chosen = picks[item.id] ?? [];
            // Option ids in the order the item lists them (question/model.ts `Selection`).
            const ordered = item.options.map((option) => option.id).filter((id) => chosen.includes(id));
            return [item.id, selection(ordered, item.allowsOther ? other[item.id] : undefined)];
          }),
        ),
      });
    } catch {
      setFailed(true);
      return;
    }
    setBusy(true);
    setFailed(false);
    send(sent).then(onSent, () => {
      setBusy(false);
      setFailed(true);
      onRefused();
    });
  };
  return (
    <form
      className="acpmux-needs-you-form"
      onSubmit={(event) => {
        event.preventDefault();
        submit();
      }}
    >
      {question.items.map((item) => (
        <fieldset key={item.id} className="acpmux-needs-you-form-item" disabled={busy}>
          <legend className="acpmux-needs-you-form-prompt">{item.prompt}</legend>
          {item.options.map((option) => (
            <label key={option.id} className="acpmux-needs-you-form-option">
              <input
                type={item.multiSelect ? "checkbox" : "radio"}
                name={`${question.id}:${item.id}`}
                aria-label={option.label}
                checked={picks[item.id]?.includes(option.id) ?? false}
                onChange={() => pick(item.id, option.id, item.multiSelect)}
              />
              <span className="acpmux-needs-you-form-label">{option.label}</span>
              {option.detail && <span className="acpmux-needs-you-form-detail">{option.detail}</span>}
            </label>
          ))}
          {item.allowsOther && (
            <input
              className="acpmux-needs-you-side-field acpmux-needs-you-form-other"
              value={other[item.id] ?? ""}
              aria-label={t("needsYou.otherAnswer")}
              placeholder={t("needsYou.otherAnswer")}
              onChange={(event) => type(item.id, event.target.value, item.multiSelect)}
            />
          )}
        </fieldset>
      ))}
      {failed && <p className="acpmux-needs-you-error">{t("needsYou.answerFailed")}</p>}
      <button type="submit" className="acpmux-needs-you-side-send" disabled={busy || !ready} aria-busy={busy}>
        {t("needsYou.submit")}
      </button>
    </form>
  );
}

/// Ask about this: a side session about the asking chat, seeded with "What is going on here?". It
/// opens beside that chat (acpmux answers there, where the person can follow up); the field closes
/// once it is asked, and says so when it could not be.
function SideQuestion({ item, ask, onAsked }: { item: NeedsYouItem; ask: NeedsYouActions["ask"]; onAsked(): void }) {
  const t = useT();
  const [draft, setDraft] = useState(() => t("needsYou.askSeed"));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const send = () => {
    const question = draft.trim();
    if (!question || busy) return;
    setBusy(true);
    setError(undefined);
    ask(item, sideQuestionPrompt(item, question)).then(onAsked, (failure: unknown) => {
      setBusy(false);
      setError(failure instanceof Error && failure.message ? failure.message : "");
    });
  };
  return (
    <div className="acpmux-needs-you-side">
      {busy && <p className="acpmux-needs-you-side-status">{t("needsYou.asking")}</p>}
      {error !== undefined && (
        <p className="acpmux-needs-you-error">
          {error ? t("needsYou.askFailedReason", { reason: error }) : t("needsYou.askFailed")}
        </p>
      )}
      <form
        className="acpmux-needs-you-side-form"
        onSubmit={(event) => {
          event.preventDefault();
          send();
        }}
      >
        <input
          className="acpmux-needs-you-side-field"
          value={draft}
          aria-label={t("needsYou.askAbout")}
          placeholder={t("needsYou.askSeed")}
          onChange={(event) => setDraft(event.target.value)}
          // oxlint-disable-next-line jsx-a11y/no-autofocus -- the field opens on the person's own click on Ask about this.
          autoFocus
        />
        <button type="submit" className="acpmux-needs-you-side-send" disabled={busy || !draft.trim()}>
          {t("needsYou.askSend")}
        </button>
      </form>
    </div>
  );
}

function Avatar({ item }: { item: NeedsYouItem }) {
  // A marked tab is in a workspace, not a chat: the workspace glyph, by its title.
  if (item.kind === "tab")
    return (
      <span className="acpmux-needs-you-avatar">
        <Icon name="workspace" size={12} />
      </span>
    );
  if (item.who.chief)
    return (
      <img
        className="acpmux-needs-you-avatar is-chief"
        src={CHIEF_AVATAR}
        alt=""
        width={16}
        height={16}
        draggable={false}
      />
    );
  return (
    <span className="acpmux-needs-you-avatar" title={item.who.harness ? agentDisplayName(item.who.harness) : undefined}>
      <AgentMark agent={item.who.harness} size={14} reserve />
    </span>
  );
}

/// The ask's line: its own text, else what its kind says (a permission asks to allow, anything
/// else for an answer).
export function askText(item: NeedsYouItem, t: Translate): string {
  // A guest's held prompt reads as its text, as a question reads as its prompt.
  if (item.kind === "held" && item.promptId) return messagePreview(item.ask);
  if (item.kind === "held") return t("needsYou.held", { n: item.held ?? 1, peer: item.ask });
  return item.ask || t(item.kind === "approval" ? "needsYou.waitingPermission" : "needsYou.waiting");
}

/// The side session's first prompt (`_acpmux/btw`): the ask, then the person's question, so the
/// side session answers about this ask from the chat's conversation without the chat re-reading.
export function sideQuestionPrompt(item: NeedsYouItem, question: string): string {
  // l10n-allow: a prompt to the agent, never shown to the person
  const lines = [
    "I am about to answer an open ask from this chat and want to understand it first.",
    `The ask (${item.kind}): ${item.ask || "waiting for my answer"}`,
    ...(item.detail ? [`Details: ${item.detail}`] : []),
    ...(item.question?.items[0]?.options.length
      ? [`Choices: ${item.question.items[0].options.map((option) => option.label).join(" / ")}`]
      : []),
    `My question: ${question}`,
    "Answer briefly from what this chat has done: what the agent is doing, why it asks, and what each answer would lead to.",
  ];
  return lines.join("\n");
}
