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
import type { AcpmuxPermission } from "../model";
import { composerPromptOf, promptHoldsDraft } from "../composerTyped";
import { harnessName } from "../permissions/planBuild";
import { permissionCommand, permissionTitle } from "../permissions/prompt";
import { focusRoute } from "../../../ui/focusRoute";
import { islandAnswers, islandExpanded, islandToggle, type IslandState } from "./model";
import "./statusIsland.css";

export type StatusIslandActions = {
  /// Sends a one-click answer (useNeedsYou's `actions.answer`); rejects when acpmux refused it.
  answer(item: NeedsYouItem, choice: NeedsYouAnswer): Promise<unknown>;
  /// Opens the ask at its source (useNeedsYou's `actions.goTo`).
  goTo(item: NeedsYouItem): void;
  /// Opens a chat by id: beside this one (the host's `chat.asks.open`), or for the chat on screen,
  /// shows its failure where it is.
  openSession(sessionId: string): void;
  /// Whether Open Chat can go anywhere for this chat (the host refuses another computer's chat and
  /// any open from New Tab). Absent: it can.
  canOpen?(sessionId: string): boolean;
};

export function StatusIsland({ state, actions }: { state: IslandState; actions: StatusIslandActions }) {
  const t = useT();
  const [pressed, setToggled] = useState<{ focus: string; open: boolean }>();
  // A press counts only while what it was about is on show (islandToggle): a failure the person
  // folded that clears and comes back opens again.
  const toggled = islandToggle(pressed, state.focus);
  useEffect(() => {
    if (pressed && !toggled) setToggled(undefined);
  }, [pressed, toggled]);
  const [sending, setSending] = useState<string>();
  const [failedFocus, setFailedFocus] = useState<string>();
  const expanded = islandExpanded(state, toggled);
  const content = useRef<HTMLDivElement>(null);
  // The pill and the card swap their content, so the control the person pressed leaves the page:
  // after their press (never after a new ask opens the card by itself) focus goes to the control
  // that stands in its place, the card's collapse button or the pill, never to the page's body.
  // Never to an answer: Return must not approve what the person has not read.
  const handoff = useRef(false);
  useEffect(() => {
    if (!handoff.current) return;
    handoff.current = false;
    const target = content.current?.querySelector<HTMLElement>(
      expanded ? ".acpmux-status-island__collapse" : ".acpmux-status-island__pill",
    );
    focusRoute(target, "person", expanded ? "status island expanded" : "status island collapsed");
  }, [expanded]);
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
    handoff.current = true;
    setToggled({ focus: state.focus, open: !expanded });
  };
  const collapse = () => {
    if (!state.focus) return;
    handoff.current = true;
    setToggled({ focus: state.focus, open: false });
  };
  // Escape belongs to the island while its card is open, wherever the keyboard is that the
  // permission card would read an Escape as Deny (permissions/prompt.ts `permissionKeyAction`): in
  // the island, on the page with nothing focused, or in the composer while it holds no draft. The
  // card opens by itself with focus left in the composer, so the person's Escape there means "put
  // this away", never Deny: the island folds and takes the key (window capture runs before the
  // permission card's document capture, and a prevented key is one it ignores). A composer with a
  // draft, another field, a menu or a dialog keeps its own Escape.
  const island = useRef<HTMLElement>(null);
  const focusKey = state.focus;
  useEffect(() => {
    if (!expanded || !focusKey) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || event.defaultPrevented || event.isComposing) return;
      const target = event.target instanceof Element ? event.target : null;
      const inIsland = Boolean(target && island.current?.contains(target));
      const nowhere = !target || target === document.body || target === document.documentElement;
      const prompt = inIsland || nowhere ? null : composerPromptOf(target);
      if (!inIsland && !nowhere && !(prompt && !promptHoldsDraft(prompt))) return;
      event.preventDefault();
      event.stopPropagation();
      // Focus follows only a press made in the island; the composer keeps the keyboard.
      handoff.current = inIsland;
      setToggled({ focus: focusKey, open: false });
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [expanded, focusKey]);
  // The request on show now. An answer goes only to the request whose button was pressed, and only
  // while it is still the one on show: a newer ask that lands mid-press gets a fresh card (IslandAsk
  // is keyed by the request), and a click that still arrives for the old one sends nothing.
  const current = useRef(state.attention?.id);
  useLayoutEffect(() => {
    current.current = state.attention?.id;
  });
  const answer = (item: NeedsYouItem, choice: NeedsYouAnswer) => {
    if (item.id !== current.current) return;
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

  // What runs is the dot and its number, no word (Leo, 2026-11-23: ""running" doesn't need text. it
  // can usually just be."); what waits on the person and an error keep theirs. The hover and VoiceOver
  // still name it ("Running · 3").
  const runningLabel = t("statusIsland.running", { n: state.running });
  const pillLabel =
    state.waiting > 0
      ? t("needsYou.pillCount", { n: state.waiting })
      : state.tone === "error"
        ? t("statusIsland.failed")
        : state.running > 0
          ? String(state.running)
          : t("statusIsland.idle");
  const pillName = state.waiting === 0 && state.tone !== "error" && state.running > 0 ? runningLabel : undefined;

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
            aria-label={pillName}
            title={pillName}
            onClick={toggle}
          >
            <span className="acpmux-status-island__dot" aria-hidden="true" />
            <span className="acpmux-status-island__label">{pillLabel}</span>
            {state.running > 0 && state.tone !== "running" && <RunningCount n={state.running} />}
          </button>
        ) : state.attention ? (
          <IslandAsk
            key={state.attention.id}
            item={state.attention}
            permission={state.permission}
            running={state.running}
            sending={sending === state.attention.id}
            failed={failedFocus === state.focus}
            onAnswer={answer}
            onOpen={actions.goTo}
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
            {(actions.canOpen?.(state.failure.sessionId) ?? true) && (
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
            )}
          </div>
        ) : null}
      </div>
    </section>
  );
}

/// How many agents run, beside what the island shows: a running dot and the number, no word; the
/// hover and VoiceOver name it ("Running · 3").
function RunningCount({ n }: { n: number }) {
  const t = useT();
  const label = t("statusIsland.running", { n });
  return (
    <span
      className="acpmux-status-island__count"
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a dot and a number with a spoken name, not an image file
      role="img"
      aria-label={label}
      title={label}
    >
      <span className="acpmux-status-island__count-dot" aria-hidden="true" />
      {n}
    </span>
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
      {running > 0 && <RunningCount n={running} />}
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
  permission,
  running,
  sending,
  failed,
  onAnswer,
  onOpen,
  onCollapse,
}: {
  item: NeedsYouItem;
  permission?: AcpmuxPermission;
  running: number;
  sending: boolean;
  failed: boolean;
  onAnswer(item: NeedsYouItem, choice: NeedsYouAnswer): void;
  onOpen(item: NeedsYouItem): void;
  onCollapse(): void;
}) {
  const t = useT();
  const answers = islandAnswers(item);
  // A command is what Allow runs: read it as the permission card does (`permissionCommand`: the
  // command, else an execute request's title), and show it whole, never as a clamped title line.
  const command = permission && !item.question ? permissionCommand(permission) : "";
  return (
    <div className="acpmux-status-island__card" data-kind={item.kind}>
      <IslandHead name={item.who.name} harness={item.who.harness} running={running} onCollapse={onCollapse} />
      <p className="acpmux-status-island__ask">
        {command && permission ? permissionTitle(permission, t) : askText(item, t)}
      </p>
      {command ? (
        <p className="acpmux-status-island__detail" data-command="">
          {command}
        </p>
      ) : (
        item.detail && (
          <p className="acpmux-status-island__detail" data-command={item.command ? "" : undefined}>
            {item.detail}
          </p>
        )
      )}
      {failed && <p className="acpmux-status-island__error">{t("needsYou.answerFailed")}</p>}
      <div
        className="acpmux-status-island__actions"
        data-choices={answers.some((choice) => choice.tone === "choice") ? "" : undefined}
      >
        {answers.map((choice) => (
          <button
            key={choice.id}
            type="button"
            className="acpmux-status-island__action"
            data-tone={choice.tone}
            disabled={sending}
            onClick={() => onAnswer(item, choice)}
          >
            {choice.label}
          </button>
        ))}
        {answers.length === 0 && (
          <button type="button" className="acpmux-status-island__action" data-tone="allow" onClick={() => onOpen(item)}>
            {t("statusIsland.open")}
          </button>
        )}
      </div>
    </div>
  );
}
