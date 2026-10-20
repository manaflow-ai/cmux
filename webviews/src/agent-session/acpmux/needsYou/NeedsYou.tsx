// The chat header's Needs you badge and its pinned list (Leo 2026-10-20), shaped like Discord's
// pinned messages: a count in the header, and a press opens every open ask in one list. Each ask
// says who asked and how long ago, answers in one click when the answer is simple (Allow, Deny, one
// of its choices), jumps to where it was asked (Go to source) and can be asked about in a side
// question seeded with the ask (Ask about this), so nobody re-reads a thread to answer it. An ask
// leaves the list once acpmux says it was answered, wherever that was (asks.ts).
import { useEffect, useRef, useState } from "react";
import { AgentMark } from "../../shared/AgentMark";
import { useMinuteClock } from "../clock";
import { RevealedMarkdown } from "../conversation/RevealedMarkdown";
import { agentDisplayName } from "../agents";
import { useT, type StringKey, type Translate } from "../i18n";
import { Icon } from "../icons/Icon";
import { shortAge } from "../sessionList";
import { Popover } from "../../../ui/Popover";
import { usePopoverTrigger } from "../../../ui/popoverTrigger";
import { onOpenNeedsYou } from "./links";
import type { NeedsYouAnswer, NeedsYouItem, NeedsYouKind } from "./model";
import "./needsYou.css";

/// The Debug choice `agentPane.debug.needsYou` (data-needs-you on <html>): `pinned` (the default)
/// draws each ask with its answers; `compact` one line per ask; `off` no badge at all.
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
  /// Asks the asking chat a side question (`_acpmux/ask`), seeded with the ask; resolves to the answer.
  ask(item: NeedsYouItem, question: string): Promise<string>;
};

const KINDS: Record<NeedsYouKind, StringKey> = {
  approval: "needsYou.kind.approval",
  decision: "needsYou.kind.decision",
  verify: "needsYou.kind.verify",
  held: "needsYou.kind.held",
  input: "needsYou.kind.input",
};

const CHIEF_AVATAR = new URL("../mascots/ChiefMascotOrb.png", import.meta.url).href;

/// The header's badge: the count of open asks; a press opens the list.
export function NeedsYouButton({
  items,
  mode = "pinned",
  actions,
  defaultOpen = false,
  githubRepository,
}: {
  items: readonly NeedsYouItem[];
  mode?: NeedsYouMode;
  actions: NeedsYouActions;
  defaultOpen?: boolean;
  githubRepository?: string;
}) {
  const t = useT();
  const [open, setOpen] = useState(defaultOpen);
  const [focus, setFocus] = useState<string>();
  const [button, setButton] = useState<HTMLButtonElement | null>(null);
  const buttonRef = useRef<HTMLButtonElement | null>(null);
  const trigger = usePopoverTrigger(open, setOpen);
  // A `cmux://needs-you/<id>` chip in a reply opens the list on its ask (links.ts).
  useEffect(
    () =>
      onOpenNeedsYou((itemId) => {
        setFocus(itemId);
        setOpen(true);
      }),
    [],
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
        title={label}
        aria-haspopup="dialog"
        aria-expanded={open}
        {...trigger}
      >
        <Icon name="inbox" size={15} />
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
        finalFocus={buttonRef}
      >
        <NeedsYouPanel
          items={items}
          mode={mode}
          actions={{
            ...actions,
            goTo: (item) => {
              setOpen(false);
              actions.goTo(item);
            },
          }}
          focus={focus}
          githubRepository={githubRepository}
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
  githubRepository,
}: {
  items: readonly NeedsYouItem[];
  mode?: NeedsYouMode;
  actions: NeedsYouActions;
  /// The ask a link opened the list on: scrolled to and marked.
  focus?: string;
  githubRepository?: string;
}) {
  const t = useT();
  const now = useMinuteClock();
  // Asks answered here, hidden until acpmux's change takes them off the list.
  const [sent, setSent] = useState<ReadonlySet<string>>(new Set());
  const shown = items.filter((item) => !sent.has(item.id));
  const missing = focus !== undefined && !items.some((item) => item.id === focus);
  return (
    <div className="acpmux-needs-you-panel" data-mode={mode}>
      <header className="acpmux-needs-you-head">
        <Icon name="state.pinned" size={14} />
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
              githubRepository={githubRepository}
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

type Asked = { question: string; answer?: string; error?: string };

function NeedsYouRow({
  item,
  mode,
  now,
  focused,
  actions,
  githubRepository,
  onSent,
  onRefused,
}: {
  item: NeedsYouItem;
  mode: NeedsYouMode;
  now: number;
  focused: boolean;
  actions: NeedsYouActions;
  githubRepository?: string;
  onSent(): void;
  onRefused(): void;
}) {
  const t = useT();
  const row = useRef<HTMLLIElement>(null);
  const [failed, setFailed] = useState(false);
  const [sending, setSending] = useState<string>();
  const [asking, setAsking] = useState(false);
  const [asked, setAsked] = useState<Asked[]>([]);
  useEffect(() => {
    if (focused) row.current?.scrollIntoView({ block: "nearest" });
  }, [focused]);
  const answer = (choice: NeedsYouAnswer) => {
    if (sending) return;
    setSending(choice.id);
    setFailed(false);
    actions.answer(item, choice).then(onSent, () => {
      setSending(undefined);
      setFailed(true);
      onRefused();
    });
  };
  const compact = mode === "compact";
  const age = shortAge(item.at, now, t);
  return (
    <li ref={row} className="acpmux-needs-you-item" data-kind={item.kind} data-focused={focused ? "" : undefined}>
      <div className="acpmux-needs-you-meta">
        <Avatar item={item} />
        <span className="acpmux-needs-you-who">{item.who.chief ? t("needsYou.chief") : item.who.name}</span>
        {item.who.via && <span className="acpmux-needs-you-via">{t("needsYou.via", { name: item.who.via })}</span>}
        <span className="acpmux-needs-you-kind">{t(KINDS[item.kind])}</span>
        {age && <span className="acpmux-needs-you-age">{age}</span>}
        <button
          type="button"
          className="acpmux-needs-you-go"
          aria-label={t("needsYou.goToSource")}
          title={t("needsYou.goToSource")}
          onClick={() => actions.goTo(item)}
        >
          <Icon name="action.go" size={14} />
        </button>
      </div>
      <p className="acpmux-needs-you-ask">{askText(item, t)}</p>
      {!compact && item.detail && (
        <p className="acpmux-needs-you-detail" data-code={item.command ? "" : undefined}>
          {item.detail}
        </p>
      )}
      {!compact && (
        <div className="acpmux-needs-you-actions">
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
              {choice.id === "resume" && item.kind === "held" ? t("needsYou.resume") : choice.label}
            </button>
          ))}
          <button
            type="button"
            className="acpmux-needs-you-ask-about"
            aria-expanded={asking}
            onClick={() => setAsking((open) => !open)}
          >
            <Icon name="agent.question" size={13} />
            {t("needsYou.askAbout")}
          </button>
        </div>
      )}
      {failed && <p className="acpmux-needs-you-error">{t("needsYou.answerFailed")}</p>}
      {asking && !compact && (
        <SideQuestion
          item={item}
          asked={asked}
          onAsked={setAsked}
          ask={actions.ask}
          githubRepository={githubRepository}
        />
      )}
    </li>
  );
}

/// Ask about this: a side question to the asking chat, seeded with "What is going on here?". Each
/// answer stays under the ask while the list is open; a follow-up carries the earlier ones.
function SideQuestion({
  item,
  asked,
  onAsked,
  ask,
  githubRepository,
}: {
  item: NeedsYouItem;
  asked: readonly Asked[];
  onAsked(next: Asked[]): void;
  ask: NeedsYouActions["ask"];
  githubRepository?: string;
}) {
  const t = useT();
  const [draft, setDraft] = useState(() => (asked.length ? "" : t("needsYou.askSeed")));
  const busy = asked.length > 0 && asked.at(-1)!.answer === undefined && asked.at(-1)!.error === undefined;
  const send = () => {
    const question = draft.trim();
    if (!question || busy) return;
    const before = asked.filter((entry) => entry.answer !== undefined);
    const pending = [...asked, { question }];
    onAsked(pending);
    setDraft("");
    ask(item, sideQuestionPrompt(item, question, before)).then(
      (answer) => onAsked([...asked, { question, answer }]),
      (error: unknown) =>
        onAsked([...asked, { question, error: error instanceof Error && error.message ? error.message : "" }]),
    );
  };
  return (
    <div className="acpmux-needs-you-side">
      {asked.map((entry, index) => (
        <div key={index} className="acpmux-needs-you-side-turn">
          <p className="acpmux-needs-you-side-q">{entry.question}</p>
          {entry.answer !== undefined ? (
            <div className="acpmux-needs-you-side-a">
              <RevealedMarkdown text={entry.answer} streaming={false} githubRepository={githubRepository} />
            </div>
          ) : entry.error !== undefined ? (
            <p className="acpmux-needs-you-error">
              {entry.error ? t("needsYou.askFailedReason", { reason: entry.error }) : t("needsYou.askFailed")}
            </p>
          ) : (
            <p className="acpmux-needs-you-side-status">{t("needsYou.asking")}</p>
          )}
        </div>
      ))}
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
  if (item.who.chief)
    return (
      <img
        className="acpmux-needs-you-avatar is-chief"
        src={CHIEF_AVATAR}
        alt=""
        width={18}
        height={18}
        draggable={false}
      />
    );
  return (
    <span className="acpmux-needs-you-avatar" title={item.who.harness ? agentDisplayName(item.who.harness) : undefined}>
      <AgentMark agent={item.who.harness} size={12} reserve />
    </span>
  );
}

/// The ask's line: its own text, else what its kind says.
export function askText(item: NeedsYouItem, t: Translate): string {
  if (item.kind === "held") return t("needsYou.held", { n: item.held ?? 1, peer: item.ask });
  return item.ask || t("needsYou.waiting");
}

/// The side question acpmux asks the chat's copy (`_acpmux/ask`): the ask, then the person's
/// question and any earlier answers, so the copy answers about this ask without the chat re-reading.
export function sideQuestionPrompt(item: NeedsYouItem, question: string, before: readonly Asked[] = []): string {
  // l10n-allow: a prompt to the agent, never shown to the person
  const lines = [
    "I am about to answer an open ask from this chat and want to understand it first.",
    `The ask (${item.kind}): ${item.ask || "waiting for my answer"}`,
    ...(item.detail ? [`Details: ${item.detail}`] : []),
    ...(item.question?.items[0]?.options.length
      ? [`Choices: ${item.question.items[0].options.map((option) => option.label).join(" / ")}`]
      : []),
    ...before.flatMap((entry) => [`Earlier I asked: ${entry.question}`, `You said: ${entry.answer ?? ""}`]),
    `My question: ${question}`,
    "Answer briefly from what this chat has done: what the agent is doing, why it asks, and what each answer would lead to.",
  ];
  return lines.join("\n");
}
