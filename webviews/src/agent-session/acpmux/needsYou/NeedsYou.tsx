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
import {
  createContext,
  memo,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type RefObject,
  useLayoutEffect,
  type CSSProperties,
  type FocusEvent,
} from "react";
import { useStableCallback } from "../stableCallback";
import { SessionMark } from "../../shared/AgentMark";
import { useLabelClock } from "../clock";
import { agentDisplayName } from "../agents";
import { HEADER_GLYPH } from "../header/chatHeaderToolsModel";
import { HeaderIcon } from "../header/HeaderIcon";
import { useT, type StringKey } from "../i18n";
import { Icon } from "../icons/Icon";
import { useAnswerHoldSet } from "../answerHold";
import { KeyHint } from "../../../ui/KeyHint";
import { nextShortAge, shortAge } from "../sessionList";
import { Popover } from "../../../ui/Popover";
import { usePopoverTrigger } from "../../../ui/popoverTrigger";
import { VirtualList } from "../../../ui/VirtualList";
import { onOpenNeedsYou } from "./links";
import type { NeedsYouAnswer, NeedsYouItem, NeedsYouKind } from "./model";
import type { AskContext } from "./context";
import { sameItemRowProps } from "./rowProps";
import { RowMemory, RowMemoryContext, useRowState } from "./rowMemory";
import { reply as questionReply, selection, type AgentQuestion, type QuestionReply } from "../question/model";
import "./needsYou.css";
import {
  answerKey,
  askText,
  sideQuestionPrompt,
  type NeedsYouActions,
  type NeedsYouMode,
  type NeedsYouPlace,
  answerButton,
  keyedLetter,
  lettered,
} from "./needsYouModel";

export type { NeedsYouActions, NeedsYouPlace } from "./needsYouModel";

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

/// What a row calls on a press. The panel hands every row the same object, which calls the latest
/// actions, so a parent's new `actions` draws no row.
type RowActions = Pick<NeedsYouActions, "answer" | "goTo" | "ask" | "reply" | "open">;

/// What the list's `actions` say during a draw (the turns before an ask, whether its chat opens
/// elsewhere), read only by an expanded row's parts (AskContextTurns, OpenPlaces): they follow the
/// chat while no row redraws for them.
const RowSources = createContext<Pick<NeedsYouActions, "context" | "opensElsewhere">>({});

/// The list draws the rows in view and NEEDS_YOU_OVERSCAN more on each side (about one 520 px list
/// of rows each way), each measured once drawn; ROW_ESTIMATE is a row's first guess before that.
const NEEDS_YOU_OVERSCAN = 6;
/// A list this short draws every row, as before the window: it is about the rows a list shows plus
/// the overscan on both sides, so drawing them all costs no more than the window would.
const WINDOW_FROM = 24;
/// A row drawn outside the window takes its place in the flow: one style object for all of them.
const IN_FLOW: CSSProperties = Object.freeze({});
const ROW_ESTIMATE: Record<NeedsYouMode, () => number> = {
  pinned: () => 88,
  compact: () => 52,
  off: () => 88,
};

type Stage = "row" | "expanded" | "context";
/// RowMemory keys for one ask's parts (rowMemory.ts).
const kept = (id: string, part: string) => `${id}\u0000${part}`;
const NO_PICKS: Readonly<Record<string, readonly string[]>> = {};
const NO_OTHER: Readonly<Record<string, string>> = {};

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
        id={trigger["aria-controls"]}
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
  // Asks answered here, hidden until acpmux's change takes them off the list, ANSWER_HOLD_MS at most
  // (answerHold.ts): one acpmux never took off (the chat ended, the answer was dropped) shows again,
  // so the list and the pill's count never disagree for long and the ask can be answered.
  const { held: sent, add: holdSent, remove: releaseSent } = useAnswerHoldSet();
  const shown = items.filter((item) => !sent.has(item.id));
  const missing = focus !== undefined && !items.some((item) => item.id === focus);
  // Each ask's row state, kept while its row is scrolled out of the drawn window.
  const [memory] = useState(() => new RowMemory());
  // The ask whose row has the keyboard: kept drawn, so focus never falls out of the list.
  const [focusWithin, setFocusWithin] = useState<string>();
  // A y or n pressed on the list for an ask outside the drawn window: drawn, then pressed.
  const [keyed, setKeyed] = useState<{ id: string; key: "y" | "n" }>();
  const activeId = focusWithin ?? keyed?.id ?? focus;
  const activeAt = activeId === undefined ? -1 : shown.findIndex((item) => item.id === activeId);
  const onFocus = (event: FocusEvent<HTMLDivElement>) => {
    const slot = (event.target as Element).closest?.("[data-item-id]");
    setFocusWithin(slot?.getAttribute("data-item-id") ?? undefined);
  };
  // y and n answer an approval as its card does: the row with focus, else the top one. The key
  // presses the row's own button, so it answers once and says so when acpmux refuses. The top one
  // is the list's, drawn or not: one outside the window is drawn first, then pressed.
  const panel = useRef<HTMLDivElement | null>(null);
  const onKey = useStableCallback((event: KeyboardEvent) => {
    const element = panel.current;
    const pressed = keyedLetter(event);
    if (!element || !pressed) return;
    let button: HTMLButtonElement | null = null;
    if (pressed.row) button = answerButton(pressed.row, pressed.key);
    else {
      // A compact row shows its answers only expanded.
      const index = shown.findIndex(
        (item) =>
          lettered(item) && (mode !== "compact" || (memory.read<Stage>(kept(item.id, "stage")) ?? "row") !== "row"),
      );
      if (index < 0) return;
      const row = element.querySelector(`[data-index="${index}"] .acpmux-needs-you-item`);
      if (!row) {
        event.preventDefault();
        event.stopPropagation();
        setKeyed({ id: shown[index]!.id, key: pressed.key });
        return;
      }
      button = answerButton(row, pressed.key);
    }
    if (!button) return;
    event.preventDefault();
    event.stopPropagation();
    button.click();
  });
  useEffect(() => {
    const element = panel.current;
    if (!element) return;
    element.addEventListener("keydown", onKey);
    return () => element.removeEventListener("keydown", onKey);
  }, [onKey]);
  // The keyed ask's row is drawn now (it is the active row): press its answer, once.
  const pressedFor = useRef<typeof keyed>(undefined);
  useLayoutEffect(() => {
    if (!keyed || pressedFor.current === keyed) return;
    pressedFor.current = keyed;
    const row = panel.current?.querySelector(`[data-item-id="${CSS.escape(keyed.id)}"] .acpmux-needs-you-item`);
    if (row) answerButton(row, keyed.key)?.click();
  }, [keyed]);
  // One set of row actions for the panel's life, each calling what `actions` holds now.
  const answer = useStableCallback((item: NeedsYouItem, choice: NeedsYouAnswer) => actions.answer(item, choice));
  const goTo = useStableCallback((item: NeedsYouItem) => actions.goTo(item));
  const ask = useStableCallback((item: NeedsYouItem, question: string) => actions.ask(item, question));
  const reply = useStableCallback((item: NeedsYouItem, sent: QuestionReply) => actions.reply!(item, sent));
  const open = useStableCallback((item: NeedsYouItem, place: NeedsYouPlace) => actions.open?.(item, place));
  const canReply = actions.reply !== undefined;
  const canOpen = actions.open !== undefined;
  const rowActions = useMemo<RowActions>(
    () => ({ answer, goTo, ask, ...(canReply ? { reply } : {}), ...(canOpen ? { open } : {}) }),
    [answer, goTo, ask, reply, open, canReply, canOpen],
  );
  const sources = useMemo(
    () => ({
      ...(actions.context ? { context: actions.context } : {}),
      ...(actions.opensElsewhere ? { opensElsewhere: actions.opensElsewhere } : {}),
    }),
    [actions.context, actions.opensElsewhere],
  );
  return (
    <div
      ref={(element) => {
        panel.current = element;
        if (panelRef) panelRef.current = element;
      }}
      className="acpmux-needs-you-panel"
      data-mode={mode}
      tabIndex={-1}
      onFocus={onFocus}
    >
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
        <RowMemoryContext.Provider value={memory}>
          <RowSources.Provider value={sources}>
            {shown.length < WINDOW_FROM ? (
              // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- the same list element as the windowed one below, whose rows are placed divs
              <div className="acpmux-needs-you-list" role="list" aria-label={t("needsYou.title")}>
                {shown.map((item, index) => (
                  <NeedsYouRow
                    key={item.id}
                    item={item}
                    index={index}
                    count={shown.length}
                    style={IN_FLOW}
                    measure={undefined}
                    mode={mode}
                    focused={item.id === focus}
                    hasContext={actions.context !== undefined}
                    actions={rowActions}
                    onSent={holdSent}
                    onRefused={releaseSent}
                  />
                ))}
              </div>
            ) : (
              // Only the rows in and near view are drawn, each measured, with the row that has the
              // keyboard, a link's ask or a keyed answer's ask kept drawn.
              <VirtualList
                className="acpmux-needs-you-list"
                // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- VirtualList draws its own element and takes the role
                role="list"
                label={t("needsYou.title")}
                count={shown.length}
                estimateSize={ROW_ESTIMATE[mode]}
                measureRows
                overscan={NEEDS_YOU_OVERSCAN}
                {...(activeAt >= 0 ? { activeIndex: activeAt, activeScrollKey: activeId } : {})}
                renderRow={(index, style, measure) => {
                  const item = shown[index]!;
                  return (
                    <NeedsYouRow
                      key={item.id}
                      item={item}
                      index={index}
                      count={shown.length}
                      style={style}
                      measure={measure}
                      mode={mode}
                      focused={item.id === focus}
                      hasContext={actions.context !== undefined}
                      actions={rowActions}
                      onSent={holdSent}
                      onRefused={releaseSent}
                    />
                  );
                }}
              />
            )}
          </RowSources.Provider>
        </RowMemoryContext.Provider>
      )}
    </div>
  );
}

/// One ask. Its own component, drawn again only when its props change: its item by value, the rest
/// by identity (rowProps.ts), so another ask's change, a focus move or a minute draws no other row.
const NeedsYouRow = memo(function NeedsYouRow({
  item,
  index,
  count,
  style,
  measure,
  mode,
  focused,
  hasContext,
  actions,
  onSent: onSentId,
  onRefused: onRefusedId,
}: {
  item: NeedsYouItem;
  /// Its place in the list and the list's length, for screen readers (aria-posinset, aria-setsize).
  index: number;
  count: number;
  /// Its place in the drawn window (VirtualList), the same object while the place holds.
  style: CSSProperties;
  measure: ((element: Element | null) => void) | undefined;
  mode: NeedsYouMode;
  focused: boolean;
  /// The list can show the turns before an ask (NeedsYouActions `context`).
  hasContext: boolean;
  actions: RowActions;
  onSent(id: string): void;
  onRefused(id: string): void;
}) {
  const t = useT();
  const row = useRef<HTMLDivElement>(null);
  // Kept in the list's memory (rowMemory.ts), so a row scrolled away and back shows the same.
  const [failed, setFailed] = useRowState(kept(item.id, "failed"), false);
  const [sending, setSending] = useRowState<string | undefined>(kept(item.id, "sending"), undefined);
  const [asking, setAsking] = useRowState(kept(item.id, "asking"), false);
  // The row's stage: the one-line card, expanded, or expanded with its context.
  const [stage, setStage] = useRowState<Stage>(kept(item.id, "stage"), "row");
  const expanded = stage !== "row";
  const itemId = item.id;
  const onSent = useCallback(() => onSentId(itemId), [onSentId, itemId]);
  const onRefused = useCallback(() => onRefusedId(itemId), [onRefusedId, itemId]);
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
    actions.answer(item, choice).then(
      () => onSent(),
      () => {
        setSending(undefined);
        setFailed(true);
        onRefused();
      },
    );
  };
  const compact = mode === "compact" && !expanded;
  // An expanded question takes its whole answer in the form; the one-click row is for the card.
  const form = expanded && item.question && item.permissionId && actions.reply ? item.question : undefined;
  const toggle = () => setStage((now) => (now === "row" ? "expanded" : "row"));
  return (
    // The list's item, placed and measured by the window; the row's look is on the element inside.
    <div
      ref={measure}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a placed, measured row inside the window's own elements, which an li cannot sit in
      role="listitem"
      className="acpmux-needs-you-slot"
      style={style}
      data-index={index}
      data-item-id={item.id}
      aria-posinset={index + 1}
      aria-setsize={count}
    >
      <div
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
            {item.at !== undefined && <NeedsYouAge at={item.at} />}
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
            id={item.id}
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
              {item.answers.map((choice) => {
                const key = answerKey(item, choice);
                return (
                  <button
                    key={choice.id}
                    type="button"
                    className="acpmux-needs-you-answer"
                    data-tone={choice.tone}
                    data-answer-key={key}
                    aria-keyshortcuts={key}
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
                    {key && <KeyHint keys={key.toUpperCase()} aria-hidden="true" />}
                  </button>
                );
              })}
            </fieldset>
          </div>
        )}
        {failed && <p className="acpmux-needs-you-error">{t("needsYou.answerFailed")}</p>}
        {expanded && (
          <div className="acpmux-needs-you-more">
            {hasContext && (
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
            {actions.open && <OpenPlaces item={item} open={actions.open} />}
          </div>
        )}
        {stage === "context" && hasContext && <AskContextTurns item={item} />}
        {asking && !compact && <SideQuestion item={item} ask={actions.ask} onAsked={() => setAsking(false)} />}
      </div>
    </div>
  );
}, sameItemRowProps);

/// The ways to open another chat's ask (on the right, its workspace, a new workspace), in an
/// expanded row when the list says its chat opens elsewhere; this chat's ask is already on screen.
function OpenPlaces({ item, open }: { item: NeedsYouItem; open: NonNullable<RowActions["open"]> }) {
  const t = useT();
  const { opensElsewhere } = useContext(RowSources);
  if (!opensElsewhere?.(item)) return null;
  return PLACES.map(({ place, label }) => (
    <button
      key={place}
      type="button"
      className="acpmux-needs-you-more-button"
      data-place={place}
      onClick={() => open(item, place)}
    >
      {t(label)}
    </button>
  ));
}

/// An ask's age ("5m"), on the pane's shared clock: it wakes only at a minute its text changes, and a
/// tick draws this label, not its row.
function NeedsYouAge({ at }: { at: number }) {
  const t = useT();
  const now = useLabelClock(at, nextShortAge);
  const age = shortAge(at, now, t);
  return age ? <span className="acpmux-needs-you-age">{age}</span> : null;
}

/// The context stage: the last turns before the ask, read-only, oldest first. Another chat's is
/// only its latest message, and says so.
function AskContextTurns({ item }: { item: NeedsYouItem }) {
  const t = useT();
  const { context: contextOf } = useContext(RowSources);
  const context: AskContext = contextOf?.(item) ?? { turns: [], partial: false };
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
  id,
  question,
  send,
  onSent,
  onRefused,
}: {
  /// The ask's id: the form's picks and text are kept under it (rowMemory.ts).
  id: string;
  question: AgentQuestion;
  send(sent: QuestionReply): Promise<unknown>;
  onSent(): void;
  onRefused(): void;
}) {
  const t = useT();
  const [picks, setPicks] = useRowState<Readonly<Record<string, readonly string[]>>>(kept(id, "picks"), NO_PICKS);
  const [other, setOther] = useRowState<Readonly<Record<string, string>>>(kept(id, "other"), NO_OTHER);
  const [busy, setBusy] = useRowState(kept(id, "formBusy"), false);
  const [failed, setFailed] = useRowState(kept(id, "formFailed"), false);
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
  const [draft, setDraft] = useRowState(kept(item.id, "draft"), t("needsYou.askSeed"));
  const [busy, setBusy] = useRowState(kept(item.id, "askBusy"), false);
  const [error, setError] = useRowState<string | undefined>(kept(item.id, "askError"), undefined);
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
      <SessionMark icon={item.who.icon} agent={item.who.harness} size={14} reserve />
    </span>
  );
}
