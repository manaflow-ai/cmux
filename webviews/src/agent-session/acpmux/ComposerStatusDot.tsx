// Leo, 2026-11-22: "if you have these random health checks they should've just been in an
// unobtrisive spot say near the bottom of the composer some sort of status dot that fades in and
// when you hover or click into it (presumably a click in you can do a click out and a hover you can
// hover out idk ab vice versa... actually this is an interesting interaction pattern...) and just
// have that be able to give you rundowns of various statuses. ... hey there's space at the bottom of
// the composer. what else could we add that fits? metadata about stuff is one. because who wants to
// open up session info these days!?"
//
// The composer status dot: one 6px dot in the composer footer, where the machine row was, that fades
// in when acpmux or the pane has something to say (a machine link coming back, a rate limit, a stuck
// harness, the pane's own reconnect, a held send) and tints by the worst of it. Hovering peeks its
// rundown card; a click, a tap or Enter pins it (peekPin.ts, schemas/composer-status/peek-pin.json).
// It lives in the footer's reserved box, so it never covers the transcript and never moves a row, and
// it never blocks a send. design/composer-status-dot.md.
import { useCallback, useEffect, useId, useState, type PointerEvent as ReactPointerEvent } from "react";
import { experimentArm } from "../../experiments/experiment";
import { HOVER_INTENT, HoverBridge, StatusCard, Keycap, focusAfterEscape, tooltipsWarm } from "./composerStatusCard";
import { composerFooterFacts } from "./composerFooterFacts.experiment";
import { composerMachineAtRest } from "./composerMachineAtRest.experiment";
import {
  counterText,
  dedupe,
  folderTail,
  hostRecoveryItem,
  nextWake,
  readComposerStatus,
  sendsHeldItem,
  shown,
  statusDueAt,
  statusWordsKey,
  worstLevel,
  type FooterFact,
  type HostRecovery,
  type StatusAction,
  type StatusItem,
} from "./composerStatusModel";
import { useHostRecovery } from "./composerStatusStore";
import { relativeTime } from "./conversation/relativeTime";
import { waitedText } from "./hostErrorModel";
import { useT, usePaneLanguage, type StringKey, type StringValues, type Translate } from "./i18n";
import { Icon } from "./icons/Icon";
import type { PeerLinkDetail } from "./linkState";
import { MachineLinkStatus } from "./MachineLinkStatus";
import { peekPin, peekPinOpen, type PeekPinEvent, type PeekPinState } from "./peekPin";
import type { PeerLink } from "./peerLink";
import { useNow } from "./subagents/subagentGroupModel";
import { focusRoute } from "../../ui/focusRoute";
import { intl } from "../../ui/intl";
import "./composerStatusDot.css";

/// A focus move inside the footer never scrolls the pane.
const QUIET: FocusOptions = { preventScroll: true };

export type FactsArm = "off" | "pulse" | "door" | "strip";

/// The machine-name-at-rest switch (composerMachineAtRest.experiment.ts).
export type MachineAtRestArm = "off" | "on";

/// The gallery's alternates (not shipped): a count of items on the dot, or a warning glyph.
export type DotLook = "dot" | "count" | "glyph";

/// What the composer passes: the chat's snapshot pieces the dot reads.
type StatusSnapshot = {
  summary?: { peer?: string; composerStatus?: unknown } | undefined;
  peerLinks?: Record<string, PeerLinkDetail> | undefined;
};

/// Whether the chat gets the dot: every chat but a remote one from an older acpmux, which says
/// neither `composerStatus` nor a link `status` (MachineLinkStatus keeps that one's row).
export function statusDotMounts(snapshot: StatusSnapshot): boolean {
  const peer = snapshot.summary?.peer;
  if (!peer) return true;
  return readComposerStatus(snapshot.summary?.composerStatus) !== undefined || !!snapshot.peerLinks?.[peer]?.status;
}

/// The composer footer's status slot (Composer.tsx `chips`): the dot with the session's items, its
/// machine link's item, and the pane's own (its connection to acpmux, a held send), or an older
/// acpmux's machine row as before.
export function ComposerStatusFoot({
  snapshot,
  link,
  heldForHost,
  onReconnectMachine,
  onResumeQueue,
}: {
  snapshot: StatusSnapshot;
  /// The chat's machine link (peerLink.ts), null for a chat on this Mac or one said elsewhere.
  link: PeerLink | null;
  heldForHost: boolean;
  onReconnectMachine?: (link: PeerLink) => void;
  onResumeQueue?: () => void;
}) {
  const mounts = statusDotMounts(snapshot);
  const host = useHostRecovery(mounts);
  if (!mounts) return <MachineLinkStatus link={link} onReconnect={onReconnectMachine} />;
  const peer = snapshot.summary?.peer;
  const status = readComposerStatus(snapshot.summary?.composerStatus);
  const linkItem = peer ? snapshot.peerLinks?.[peer]?.status : undefined;
  // One line per cause (peerLink.ts): a link the peer copy banner already says stays out of the dot,
  // unless a person must act on it.
  const linkShown = linkItem && (link !== null || linkItem.level === "problem") ? [linkItem] : [];
  const held = sendsHeldItem(heldForHost);
  const items = [...(status?.items ?? []), ...linkShown, ...(held ? [held] : [])];
  const reconnect = link && onReconnectMachine && !link.stuck ? () => onReconnectMachine(link) : undefined;
  return (
    <ComposerStatusDot
      items={items}
      host={host}
      facts={status?.facts}
      connectedTo={link?.link === "connected" ? link.machine : undefined}
      onAction={(action) =>
        action === "reconnect" ? reconnect?.() : action === "resumeQueue" ? onResumeQueue?.() : undefined
      }
      actions={actionSet(!!reconnect, !!onResumeQueue)}
    />
  );
}

const NO_ACTIONS: ReadonlySet<StatusAction> = new Set();
const RECONNECT: ReadonlySet<StatusAction> = new Set(["reconnect"]);
const RESUME: ReadonlySet<StatusAction> = new Set(["resumeQueue"]);
const BOTH: ReadonlySet<StatusAction> = new Set(["reconnect", "resumeQueue"]);
const actionSet = (reconnect: boolean, resume: boolean) =>
  reconnect ? (resume ? BOTH : RECONNECT) : resume ? RESUME : NO_ACTIONS;

/// The action buttons' words. signIn and update have no path from the composer yet: no button.
const ACTION_WORDS: Partial<Record<StatusAction, StringKey>> = {
  reconnect: "machineLink.reconnect",
  resumeQueue: "composer.queueResume",
};

const FACT_WORDS: Record<FooterFact["kind"], StringKey> = {
  machine: "composerStatus.fact.machine",
  folder: "composerStatus.fact.folder",
  branch: "composerStatus.fact.branch",
  harness: "composerStatus.fact.harness",
  model: "composerStatus.fact.model",
  context: "composerStatus.fact.context",
  turn: "composerStatus.fact.turn",
  subagents: "composerStatus.fact.subagents",
  queued: "composerStatus.fact.queued",
};

const ESC = "esc"; // l10n-allow: the Escape key's name as keyboards print it, in its keycap

const COUNTERS = [
  { kind: "subagents", icon: "agent.bot", words: "composerStatus.subagentsCount" },
  { kind: "queued", icon: "view.list", words: "composerStatus.queuedCount" },
] as const satisfies readonly { kind: FooterFact["kind"]; icon: string; words: StringKey }[];

const STRIP_KINDS = ["machine", "folder", "branch", "context", "turn"] as const;

/// An item's words, or undefined for a key this build does not know (never the raw key).
export function itemWords(item: StatusItem, t: Translate, lang: string): string | undefined {
  const key = statusWordsKey(item);
  if (!key) return undefined;
  const values: StringValues = {};
  if (item.subject !== undefined) values.subject = item.subject;
  if (item.until !== undefined) values.time = clockTime(item.until, lang);
  return t(key, values);
}

const clockTime = (at: number, lang: string) =>
  intl.DateTimeFormat(lang, { hour: "numeric", minute: "2-digit" }).format(new Date(at));

/// A fact's value as the card writes it, and the row's tooltip; undefined when it has none.
function factValue(fact: FooterFact, now: number, lang: string): { text: string; title?: string } | undefined {
  switch (fact.kind) {
    case "folder":
      return fact.text ? { text: folderTail(fact.text), title: fact.text } : undefined;
    case "context":
      return fact.fraction === undefined
        ? undefined
        : { text: intl.NumberFormat(lang, { style: "percent", maximumFractionDigits: 0 }).format(fact.fraction) };
    case "turn":
      return fact.since === undefined ? undefined : { text: waitedText(Math.max(0, now - fact.since)) };
    case "subagents":
    case "queued":
      return fact.count === undefined ? undefined : { text: intl.NumberFormat(lang).format(fact.count) };
    default:
      return fact.text ? { text: fact.text } : undefined;
  }
}

/// The card's states and the hover bridge, outside React's render: the dot's handlers, its timers and
/// its document listeners dispatch here, and only the state is React's.
class PeekPinDriver {
  dot: HTMLButtonElement | null = null;
  card: HTMLDivElement | null = null;
  readonly bridge: HoverBridge;

  constructor(
    public state: PeekPinState,
    private readonly render: (state: PeekPinState) => void,
  ) {
    this.bridge = new HoverBridge({
      dwell: HOVER_INTENT.tooltipDelay,
      grace: HOVER_INTENT.cardGrace,
      open: () => this.dispatch("hoverIntent"),
      close: () => this.dispatch("hoverEnd"),
    });
  }

  attachDot(node: HTMLButtonElement | null): void {
    this.dot = node;
  }

  attachCard(node: HTMLDivElement | null): void {
    this.card = node;
  }

  dispatch(event: PeekPinEvent): void {
    const step = peekPin(this.state, event);
    const moved = step.state !== this.state;
    this.state = step.state;
    if (moved) this.render(step.state);
    for (const effect of step.effects) {
      if (effect === "stopHover") this.bridge.stop();
      else if (effect === "focusDot") focusAfterEscape(this.dot);
      else if (effect === "focusCard") setTimeout(() => this.focusCard());
    }
  }

  /// The card's first action, else the card itself.
  focusCard(): void {
    const card = this.card;
    if (!card || !card.isConnected) return;
    const first = this.actions()[0];
    if (first) focusRoute(first, "person", "pinned the status card: its first action", QUIET);
    else {
      card.tabIndex = -1;
      focusRoute(card, "person", "pinned the status card: the card itself", QUIET);
    }
  }

  actions(): HTMLElement[] {
    return this.card ? [...this.card.querySelectorAll<HTMLElement>("button:not([disabled])")] : [];
  }

  rects() {
    return { trigger: this.dot?.getBoundingClientRect(), card: this.card?.getBoundingClientRect() };
  }
}

export type ComposerStatusDotProps = {
  /// Every item from every source, in any order: the dot keeps the due ones, one per kind.
  items: readonly StatusItem[];
  /// The pane's own recovery (composerStatusStore.ts), made an item by the dot's own clock.
  host?: HostRecovery;
  facts?: readonly FooterFact[];
  /// The chat's machine while its link is up: the resting dot is the success green.
  connectedTo?: string;
  onAction?: (action: StatusAction) => void;
  /// The actions the composer can run; an item's other action draws no button.
  actions?: ReadonlySet<StatusAction>;
  /// The footer facts arm (composerFooterFacts.experiment.ts); the pane passes none and reads it.
  arm?: FactsArm;
  /// The machine-name-at-rest switch (composerMachineAtRest.experiment.ts); the pane passes none and
  /// reads it.
  machineAtRest?: MachineAtRestArm;
  /// A fixed clock, for the gallery and tests; the pane passes none.
  now?: number;
  /// The card's first state, for the gallery.
  initial?: PeekPinState;
  look?: DotLook;
};

export function ComposerStatusDot({
  items,
  host,
  facts = [],
  connectedTo,
  onAction,
  actions = NO_ACTIONS,
  arm: fixedArm,
  machineAtRest: fixedMachineAtRest,
  now: fixedNow,
  initial = "closed",
  look = "dot",
}: ComposerStatusDotProps) {
  const t = useT();
  const lang = usePaneLanguage();
  const cardId = useId();
  const arm = fixedArm ?? experimentArm(composerFooterFacts);
  const machineAtRest = fixedMachineAtRest ?? experimentArm(composerMachineAtRest);
  const [state, setState] = useState<PeekPinState>(initial);
  const [driver] = useState(() => new PeekPinDriver(initial, setState));
  const [dot, setDotNode] = useState<HTMLButtonElement | null>(null);
  const setDot = useCallback(
    (node: HTMLButtonElement | null) => {
      driver.attachDot(node);
      setDotNode(node);
    },
    [driver],
  );
  const setCard = useCallback(
    (node: HTMLDivElement | null) => {
      driver.attachCard(node);
    },
    [driver],
  );

  // One clock: it wakes at the earliest item still to come, and only then.
  const [tick, setTick] = useState(() => Date.now());
  const clock = fixedNow ?? tick;
  const recovery = hostRecoveryItem(host, clock);
  const all = recovery.item ? [...items, recovery.item] : items;
  const wake = fixedNow === undefined ? nextWake([...all.map(statusDueAt), recovery.wakeAt], clock) : undefined;
  useEffect(() => {
    if (wake === undefined) return;
    // When it fires, its moment has come, even on a timer that ran a little early.
    const timer = setTimeout(() => setTick(Math.max(Date.now(), wake)), Math.max(0, wake - Date.now()));
    return () => clearTimeout(timer);
  }, [wake]);

  const open = peekPinOpen(state);
  const turn = facts.some((fact) => fact.kind === "turn" && fact.since !== undefined);
  const ticking = useNow(open && fixedNow === undefined);
  const now = open && fixedNow === undefined ? Math.max(clock, ticking) : clock;

  const visible = dedupe(shown(all, clock));
  const worst = worstLevel(visible);
  const factsOn = arm !== "off" && facts.length > 0;
  const counters = arm === "pulse" || arm === "strip" ? facts : [];
  // The machine a chat on another machine runs on, when acpmux marks it worth its name at rest and the
  // switch is on; the strip arm already writes it in its line.
  const restingMachine =
    machineAtRest === "on" && arm !== "strip"
      ? facts.find((fact) => fact.kind === "machine" && fact.atRest && fact.text)?.text
      : undefined;
  const shows = worst !== undefined || connectedTo !== undefined || factsOn || restingMachine !== undefined;
  const tone = worst ?? (connectedTo !== undefined ? "connected" : "resting");
  const first = visible[0];
  const firstWords = first ? itemWords(first, t, lang) : undefined;
  const label = firstWords ?? t("composerStatus.details");
  const problem = visible.find((item) => item.level === "problem");
  const announce = problem ? itemWords(problem, t, lang) : undefined;
  const statusRows = visible.length > 0 || connectedTo !== undefined;
  const sessionRows = factsOn ? facts.flatMap((fact) => (factValue(fact, turn ? now : clock, lang) ? [fact] : [])) : [];

  // With nothing left to say, the card goes.
  const empty = !shows || (!statusRows && sessionRows.length === 0);
  useEffect(() => {
    if (empty) driver.dispatch("empty");
  }, [empty, driver]);

  // While it peeks, the bridge follows the pointer across the gap to the card.
  useEffect(() => {
    if (state !== "peek") return;
    const move = (event: PointerEvent) => {
      driver.bridge.update(driver.rects());
      driver.bridge.move({ x: event.clientX, y: event.clientY });
    };
    document.addEventListener("pointermove", move, { passive: true });
    return () => document.removeEventListener("pointermove", move);
  }, [state, driver]);

  // While it shows: a press elsewhere closes it, Escape closes it before the prompt's own Escape, and
  // Tab walks the card's actions and back to the dot.
  useEffect(() => {
    if (!open) return;
    const pressed = (event: PointerEvent) => {
      const target = event.target instanceof Node ? event.target : null;
      if (target && driver.dot?.contains(target)) return;
      driver.dispatch(target && driver.card?.contains(target) ? "pressCard" : "pressOutside");
    };
    const key = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        driver.dispatch("escape");
        return;
      }
      if (event.key !== "Tab" || driver.state !== "pinned") return;
      const actions = driver.actions();
      const active = document.activeElement;
      if (active === driver.dot && !event.shiftKey) {
        event.preventDefault();
        driver.focusCard();
      } else if (active instanceof HTMLElement && driver.card?.contains(active)) {
        const at = actions.indexOf(active);
        const edge = event.shiftKey ? at <= 0 : at === actions.length - 1 || at < 0;
        if (edge) {
          event.preventDefault();
          focusRoute(driver.dot, "person", "Tab past the status card: back to the dot", QUIET);
        }
      }
    };
    document.addEventListener("pointerdown", pressed, true);
    document.addEventListener("keydown", key, true);
    return () => {
      document.removeEventListener("pointerdown", pressed, true);
      document.removeEventListener("keydown", key, true);
    };
  }, [open, driver]);

  useEffect(() => () => driver.bridge.stop(), [driver]);

  const enterDot = (event: ReactPointerEvent<HTMLButtonElement>) => {
    // A touch has no hover: its tap pins.
    if (event.pointerType === "touch" || !shows) return;
    if (driver.state === "pinned" || driver.state === "held") return;
    if (driver.state === "closed" && driver.bridge.open) driver.bridge.stop();
    const rects = driver.rects();
    driver.bridge.enter("trigger", rects.trigger, { x: event.clientX, y: event.clientY }, tooltipsWarm());
  };
  const leaveDot = (event: ReactPointerEvent<HTMLButtonElement>) => {
    if (event.pointerType === "touch") return;
    driver.dispatch("pointerLeaveDot");
    driver.bridge.leave("trigger", driver.rects().trigger, { x: event.clientX, y: event.clientY });
  };
  const press = (event: { detail: number }) => driver.dispatch(event.detail === 0 ? "keyActivate" : "clickDot");

  // The strip arm: the static facts as one quiet line in the row's free middle.
  const stripText =
    arm === "strip"
      ? STRIP_KINDS.flatMap((kind) => {
          const fact = facts.find((each) => each.kind === kind);
          const value = fact ? factValue(fact, turn ? now : clock, lang) : undefined;
          return value ? [value.text] : [];
        }).join(" · ")
      : "";

  const live = COUNTERS.map((counter) => {
    const fact = counters.find((each) => each.kind === counter.kind && each.live && (each.count ?? 0) > 0);
    return { ...counter, count: fact?.count ?? 0, on: fact !== undefined };
  });

  return (
    <span className="acpmux-composer-status" data-arm={arm}>
      <button
        ref={setDot}
        type="button"
        className="acpmux-composer-status-dot"
        data-tone={tone}
        data-shown={shows ? "" : undefined}
        data-look={look}
        aria-label={label}
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-controls={open ? cardId : undefined}
        tabIndex={shows ? 0 : -1}
        onPointerEnter={enterDot}
        onPointerLeave={leaveDot}
        onClick={press}
        onFocus={(event) => {
          if (event.currentTarget.matches(":focus-visible")) driver.dispatch("focusVisible");
        }}
        onBlur={(event) => {
          const next = event.relatedTarget instanceof Node ? event.relatedTarget : null;
          if (!next || !driver.card?.contains(next)) driver.dispatch("blur");
        }}
      >
        <span className="acpmux-composer-status-pip" aria-hidden="true" />
        {look === "count" && visible.length > 1 ? (
          <span className="acpmux-composer-status-badge" aria-hidden="true">
            {counterText(visible.length)}
          </span>
        ) : null}
        {look === "glyph" && worst === "problem" ? <Icon name="status.warning" size={12} /> : null}
      </button>
      {restingMachine !== undefined ? (
        <button
          type="button"
          className="acpmux-composer-status-machine"
          title={restingMachine}
          tabIndex={-1}
          onClick={press}
        >
          {restingMachine}
        </button>
      ) : null}
      {arm === "pulse" || arm === "strip"
        ? live.map((counter) => (
            <button
              key={counter.kind}
              type="button"
              className="acpmux-composer-status-count"
              data-shown={counter.on ? "" : undefined}
              aria-label={t(counter.words, { count: counter.count })}
              tabIndex={counter.on ? 0 : -1}
              onClick={press}
            >
              <Icon name={counter.icon} size={12} />
              <span className="acpmux-composer-status-number">{counterText(counter.count)}</span>
            </button>
          ))
        : null}
      {arm === "strip" && stripText ? <span className="acpmux-composer-status-strip">{stripText}</span> : null}
      <span className="ui-sr-only" aria-live="polite">
        {announce ?? ""}
      </span>
      <StatusCard
        id={cardId}
        anchor={dot}
        open={open && !empty}
        pinned={state === "pinned"}
        label={label}
        popupRef={setCard}
        onPointerEnter={() => driver.bridge.enter("card", driver.rects().card)}
        onPointerLeave={() => driver.bridge.leave("card", driver.rects().card)}
      >
        <div className="acpmux-status-rundown">
          {statusRows && sessionRows.length > 0 ? (
            <div className="acpmux-status-heading">{t("composerStatus.title")}</div>
          ) : null}
          {statusRows ? (
            <ul className="acpmux-status-list">
              {visible.length === 0 && connectedTo !== undefined ? (
                <li className="acpmux-status-row" data-tone="connected">
                  <span className="acpmux-status-row-dot" aria-hidden="true" />
                  <span className="acpmux-status-row-words">
                    {t("composerStatus.connectedTo", { subject: connectedTo })}
                  </span>
                </li>
              ) : null}
              {visible.map((item) => {
                const words = itemWords(item, t, lang);
                if (!words) return null;
                const when =
                  item.since !== undefined
                    ? relativeTime(item.since, now, lang)
                    : item.until !== undefined
                      ? clockTime(item.until, lang)
                      : undefined;
                const action = item.action && actions.has(item.action) ? item.action : undefined;
                const actionWords = action ? ACTION_WORDS[action] : undefined;
                return (
                  <li key={item.kind} className="acpmux-status-row" data-tone={item.level}>
                    <span className="acpmux-status-row-dot" aria-hidden="true" />
                    <span className="acpmux-status-row-words">{words}</span>
                    {when ? <span className="acpmux-status-row-time">{when}</span> : null}
                    {action && actionWords ? (
                      <button type="button" className="acpmux-status-action" onClick={() => onAction?.(action)}>
                        {t(actionWords)}
                      </button>
                    ) : null}
                  </li>
                );
              })}
            </ul>
          ) : null}
          {statusRows && sessionRows.length > 0 ? (
            <div className="acpmux-status-heading">{t("composerStatus.session")}</div>
          ) : null}
          {sessionRows.length > 0 ? (
            <dl className="acpmux-status-facts">
              {sessionRows.map((fact) => {
                const value = factValue(fact, now, lang);
                return (
                  <div key={fact.kind} className="acpmux-status-fact" title={value?.title}>
                    <dt>{t(FACT_WORDS[fact.kind])}</dt>
                    <dd>{value?.text}</dd>
                  </div>
                );
              })}
            </dl>
          ) : null}
          <div className="acpmux-status-hint" data-shown={state === "pinned" ? "" : undefined}>
            <Keycap>{ESC}</Keycap>
            {t("contextScreen.close")}
          </div>
        </div>
      </StatusCard>
    </span>
  );
}
