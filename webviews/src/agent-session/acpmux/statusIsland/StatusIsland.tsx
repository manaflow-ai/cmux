// The agent status island (Taste Board #38 and #143; experiment `agent-status-island`, off by
// default): a small floating pill at the top of the chat. Compact, it is a dot and how many agents
// run. When an agent needs the person it morphs in place, on the house spring and with no modal,
// into a card: who asks, the ask, and its one-click answers (the Needs you answers, sent through
// the same `actions.answer` the Needs you list and the permission card use). Once acpmux says the
// ask was answered, wherever, the card morphs back into the pill. A failed agent gets the same card
// with its error and Open chat. A press on the pill expands or collapses it; Escape collapses it.
//
// It replaces nothing: the permission cards, Needs you and the sidebar dots stay as they are.
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { useT } from "../i18n";
import type { NeedsYouAnswer, NeedsYouItem } from "../needsYou/model";
import { askText } from "../needsYou/needsYouModel";
import { harnessName } from "../permissions/planBuild";
import { islandAnswers, islandExpanded, type IslandState } from "./model";
import "./statusIsland.css";

export type StatusIslandActions = {
  /// Sends a one-click answer (useNeedsYou's `actions.answer`); rejects when acpmux refused it.
  answer(item: NeedsYouItem, choice: NeedsYouAnswer): Promise<unknown>;
  /// Opens the ask at its source (useNeedsYou's `actions.goTo`).
  goTo(item: NeedsYouItem): void;
  /// Opens a chat by id, beside this one (the host's `chat.asks.open`).
  openSession(sessionId: string): void;
};

export function StatusIsland({ state, actions }: { state: IslandState; actions: StatusIslandActions }) {
  const t = useT();
  const [toggled, setToggled] = useState<{ focus: string; open: boolean }>();
  const [sending, setSending] = useState<string>();
  const [failedFocus, setFailedFocus] = useState<string>();
  const expanded = islandExpanded(state, toggled);
  const content = useRef<HTMLDivElement>(null);
  const [size, setSize] = useState<{ width: number; height: number }>();

  // The island's box follows its content's size, so width, height and corner radius run on the
  // spring between the pill and the card (a box sized by its content alone would jump).
  useLayoutEffect(() => {
    const inner = content.current;
    if (!inner) return;
    const measure = () => {
      const next = { width: inner.offsetWidth, height: inner.offsetHeight };
      setSize((last) => (last && last.width === next.width && last.height === next.height ? last : next));
    };
    measure();
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(measure);
    observer.observe(inner);
    return () => observer.disconnect();
    // The content remounts between the pill and the card (its `key`): observe the new one.
  }, [expanded]);

  const toggle = () => {
    if (!state.focus) return;
    setToggled({ focus: state.focus, open: !expanded });
  };
  const collapse = () => {
    if (state.focus) setToggled({ focus: state.focus, open: false });
  };
  // Escape inside the card folds it back into the pill (a native listener: the island is a region,
  // not a control, so its own buttons keep their keys).
  const island = useRef<HTMLElement>(null);
  const focusKey = state.focus;
  useEffect(() => {
    const node = island.current;
    if (!node || !expanded || !focusKey) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.stopPropagation();
      setToggled({ focus: focusKey, open: false });
    };
    node.addEventListener("keydown", onKey);
    return () => node.removeEventListener("keydown", onKey);
  }, [expanded, focusKey]);
  const answer = (item: NeedsYouItem, choice: NeedsYouAnswer) => {
    setSending(item.id);
    setFailedFocus(undefined);
    actions.answer(item, choice).then(
      () => setSending(undefined),
      () => {
        setSending(undefined);
        setFailedFocus(state.focus);
      },
    );
  };

  const pillLabel =
    state.waiting > 0
      ? t("needsYou.pillCount", { n: state.waiting })
      : state.tone === "error"
        ? t("statusIsland.failed")
        : state.running > 0
          ? t("statusIsland.running", { n: state.running })
          : t("statusIsland.idle");

  return (
    <section
      ref={island}
      className="ui-glass ui-glass-floats acpmux-status-island"
      aria-label={t("statusIsland.label")}
      data-tone={state.tone}
      data-expanded={expanded ? "" : undefined}
      style={size ? { width: size.width, height: size.height } : undefined}
    >
      <div ref={content} className="acpmux-status-island__content" key={expanded ? "card" : "pill"}>
        {!expanded ? (
          <button
            type="button"
            className="acpmux-status-island__pill"
            aria-expanded={state.focus ? false : undefined}
            disabled={!state.focus}
            onClick={toggle}
          >
            <span className="acpmux-status-island__dot" aria-hidden="true" />
            <span className="acpmux-status-island__label">{pillLabel}</span>
            {state.running > 0 && state.tone !== "running" && (
              <span className="acpmux-status-island__count">{t("statusIsland.running", { n: state.running })}</span>
            )}
          </button>
        ) : state.attention ? (
          <IslandAsk
            item={state.attention}
            running={state.running}
            sending={sending === state.attention.id}
            failed={failedFocus === state.focus}
            onAnswer={(choice) => state.attention && answer(state.attention, choice)}
            onOpen={() => state.attention && actions.goTo(state.attention)}
            onCollapse={collapse}
          />
        ) : state.failure ? (
          <div className="acpmux-status-island__card">
            <IslandHead
              name={state.failure.name}
              harness={state.failure.harness}
              running={state.running}
              onCollapse={collapse}
            />
            <p className="acpmux-status-island__ask">{t("statusIsland.failed")}</p>
            {state.failure.error && <p className="acpmux-status-island__detail">{state.failure.error}</p>}
            <div className="acpmux-status-island__actions">
              <button
                type="button"
                className="acpmux-status-island__action"
                data-tone="allow"
                onClick={() => state.failure && actions.openSession(state.failure.sessionId)}
              >
                {t("statusIsland.open")}
              </button>
            </div>
          </div>
        ) : null}
      </div>
    </section>
  );
}

function IslandHead({
  name,
  harness,
  running,
  onCollapse,
}: {
  name: string;
  harness?: string;
  running: number;
  onCollapse(): void;
}) {
  const t = useT();
  return (
    <div className="acpmux-status-island__head">
      <span className="acpmux-status-island__dot" aria-hidden="true" />
      <strong className="acpmux-status-island__name">{name}</strong>
      {harness && <span className="acpmux-status-island__harness">{harnessName(harness)}</span>}
      {running > 0 && <span className="acpmux-status-island__count">{t("statusIsland.running", { n: running })}</span>}
      <button
        type="button"
        className="acpmux-status-island__collapse"
        aria-label={t("statusIsland.collapse")}
        aria-expanded={true}
        onClick={onCollapse}
      >
        <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true">
          <path
            d="M3 7.5 6 4.5 9 7.5"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.5"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
      </button>
    </div>
  );
}

function IslandAsk({
  item,
  running,
  sending,
  failed,
  onAnswer,
  onOpen,
  onCollapse,
}: {
  item: NeedsYouItem;
  running: number;
  sending: boolean;
  failed: boolean;
  onAnswer(choice: NeedsYouAnswer): void;
  onOpen(): void;
  onCollapse(): void;
}) {
  const t = useT();
  const answers = islandAnswers(item);
  return (
    <div className="acpmux-status-island__card" data-kind={item.kind}>
      <IslandHead name={item.who.name} harness={item.who.harness} running={running} onCollapse={onCollapse} />
      <p className="acpmux-status-island__ask">{askText(item, t)}</p>
      {item.detail && (
        <p className="acpmux-status-island__detail" data-command={item.command ? "" : undefined}>
          {item.detail}
        </p>
      )}
      {failed && <p className="acpmux-status-island__error">{t("needsYou.answerFailed")}</p>}
      <div className="acpmux-status-island__actions">
        {answers.map((choice) => (
          <button
            key={choice.id}
            type="button"
            className="acpmux-status-island__action"
            data-tone={choice.tone}
            disabled={sending}
            onClick={() => onAnswer(choice)}
          >
            {choice.label}
          </button>
        ))}
        {answers.length === 0 && (
          <button type="button" className="acpmux-status-island__action" data-tone="allow" onClick={onOpen}>
            {t("statusIsland.open")}
          </button>
        )}
      </div>
    </div>
  );
}
