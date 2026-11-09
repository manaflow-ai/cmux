// Who wrote the lines of an edit in the chat (EditDiffHunks.tsx): the first line the pointer
// enters in one of the card's numbered edits asks acpmux for the card's added lines (hover implies
// the card is on screen; a card nobody hovers never asks). A hovered added line that a recorded turn
// wrote shows a dot in its number gutter (Pierre's gutter utility, placed on the hovered line, so
// nothing in the diff moves); resting on it shows the writers' card, and a click opens the newest
// writer's turn. A line no turn wrote shows nothing.
import {
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
  type FocusEvent,
  type PointerEvent,
  type ReactNode,
} from "react";
import { AnchoredCard } from "../../../ui/Tooltip";
import { HOVER_INTENT, HoverGroup, useHoverIntent } from "../../../ui/hoverIntent";
import type { UiAnchorRect } from "../../../ui/Popover";
import type { TurnFile } from "../diff";
import { useT } from "../i18n";
import { sessionLink } from "../links";
import {
  addedLines,
  addedTexts,
  attributionKey,
  targetOf,
  type Attribution,
  type AttributionStore,
  type AttributionTarget,
} from "./attribution";
import { AttributionCardContent } from "./AttributionCard";
import { AttributionContext, type AttributionSource } from "./attributionContext";

/// The pointer's rest on a marker before its card shows: a tooltip's, since the dot is small and
/// sits where the pointer passes on its way along the lines.
const ATTRIBUTION_DELAY = HOVER_INTENT.tooltipDelay;

/// One group for every diff's markers: after one card, the next line's shows at once.
const group = new HoverGroup(HOVER_INTENT.cardGrace);

/// The added line under the pointer, for the marker alone: a move from line to line repaints only it.
class HoveredLine {
  private line: number | undefined;
  private readonly listeners = new Set<() => void>();
  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  };
  get = () => this.line;
  set(line: number | undefined) {
    if (line === this.line) return;
    this.line = line;
    for (const listener of this.listeners) listener();
  }
}

/// Pierre's line event, as much of it as the marker reads.
type LineEvent = { lineNumber: number; lineType: string };

type Shown = { writers: readonly Attribution[]; anchor: UiAnchorRect };

/// What a marker asks of its diff's hover: show its writers' card at it (`delay` 0 for focus),
/// put it away after the grace, or now.
type MarkerActions = {
  show(writers: readonly Attribution[], at: Element, delay?: number): void;
  go(): void;
  now(): void;
};

export type EditAttribution = {
  /// Merged into a numbered edit's Pierre options.
  options: { enableGutterUtility: true; onLineEnter(line: LineEvent): void; onLineLeave(): void } | undefined;
  /// FileDiff's `renderGutterUtility` for a numbered edit.
  renderGutterUtility: (() => ReactNode) | undefined;
  /// The writers' card, portaled over the page, never in the diff's flow.
  card: ReactNode;
};

/// The attribution of `file`'s edits: nothing without a source (`AttributionContext`), a canonical
/// path or a numbered edit.
export function useEditAttribution(file: TurnFile): EditAttribution {
  const source = useContext(AttributionContext);
  const canonical = file.canonical;
  const enabled = Boolean(source && canonical && file.edits.some((edit) => edit.numbered && edit.hunks.length));
  const [target, setTarget] = useState<AttributionTarget | undefined>(undefined);
  const hovered = useMemo(() => new HoveredLine(), []);
  // The text each added line shows: an answer counts only for the lines the file still holds.
  const texts = useMemo(() => addedTexts(file), [file]);
  const latest = useRef({ source, file, target, texts });
  latest.current = { source, file, target, texts };

  const options = useMemo<EditAttribution["options"]>(() => {
    if (!enabled) return undefined;
    const ask = () => {
      const { source: current, file: shown, texts: showing } = latest.current;
      if (!current) return;
      void current.repo().then((repo) => {
        const next = targetOf(shown.canonical, repo);
        if (!next) return;
        const key = attributionKey(next);
        const known = latest.current.target;
        if (!known || attributionKey(known) !== key) setTarget(next);
        // The store skips what it holds, so a file it let go of is asked again.
        current.store.want(next, addedLines(shown), showing);
      });
    };
    return {
      enableGutterUtility: true,
      onLineEnter: (line) => {
        hovered.set(line.lineType === "change-addition" ? line.lineNumber : undefined);
        ask();
      },
      onLineLeave: () => hovered.set(undefined),
    };
  }, [enabled, hovered]);

  const intent = useHoverIntent<Shown>({ delay: ATTRIBUTION_DELAY, group });
  const { hover: point, dismiss } = intent;
  const leave = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const stay = () => {
    clearTimeout(leave.current);
    leave.current = undefined;
  };
  const go = () => {
    stay();
    leave.current = setTimeout(() => {
      leave.current = undefined;
      point(null);
    }, HOVER_INTENT.cardGrace);
  };
  const now = () => {
    stay();
    dismiss();
  };
  const latestNow = useRef(now);
  latestNow.current = now;
  useEffect(() => () => clearTimeout(leave.current), []);
  // The card follows its marker when the transcript scrolls itself (a working chat follows its
  // output), once a frame, and goes when the marker leaves the page or the window; the person's own
  // wheel puts it away. The listeners live while it shows.
  const shown = intent.shown;
  const anchorAt = useRef<Element | null>(null);
  const latestShown = useRef(shown);
  latestShown.current = shown;
  useEffect(() => {
    if (!shown) return;
    const close = () => latestNow.current();
    let frame = 0;
    const follow = () => {
      if (frame) return;
      frame = requestAnimationFrame(() => {
        frame = 0;
        const at = anchorAt.current;
        const card = latestShown.current;
        if (!at?.isConnected || !card) return close();
        const box = at.getBoundingClientRect();
        if (box.bottom < 0 || box.top > window.innerHeight) return close();
        point(
          { writers: card.writers, anchor: { left: box.left, top: box.top, right: box.right, bottom: box.bottom } },
          0,
        );
      });
    };
    window.addEventListener("scroll", follow, { capture: true, passive: true });
    window.addEventListener("wheel", close, { capture: true, passive: true });
    return () => {
      cancelAnimationFrame(frame);
      window.removeEventListener("scroll", follow, { capture: true });
      window.removeEventListener("wheel", close, { capture: true });
    };
  }, [shown, point]);

  const marker = useRef<MarkerActions>({ show: () => undefined, go, now });
  marker.current = {
    show: (writers, at, delay) => {
      stay();
      anchorAt.current = at;
      const box = at.getBoundingClientRect();
      point({ writers, anchor: { left: box.left, top: box.top, right: box.right, bottom: box.bottom } }, delay);
    },
    go,
    now,
  };
  const store = source?.store;
  const renderGutterUtility = useMemo(
    () =>
      enabled && store
        ? () => <AttributionMarker hovered={hovered} store={store} target={target} actions={marker} source={latest} />
        : undefined,
    [enabled, store, target, hovered],
  );

  const popup = useRef<HTMLDivElement | null>(null);
  const card =
    source && shown ? (
      <AnchoredCard
        anchor={shown.anchor}
        side="bottom"
        open
        instant
        interactive
        className="ui-glass-floats cv-attribution-card"
        onPointerEnter={stay}
        onPointerLeave={go}
        popupRef={popup}
      >
        <AttributionCardContent
          writers={shown.writers}
          currentSessionId={source.sessionId}
          onReveal={(turnId) => {
            now();
            source.reveal(turnId);
          }}
          onFocus={stay}
          onBlur={(event: FocusEvent<HTMLElement>) => {
            if (!(event.relatedTarget instanceof Node && popup.current?.contains(event.relatedTarget))) go();
          }}
        />
      </AnchoredCard>
    ) : null;
  return { options, renderGutterUtility, card };
}

/// The dot on a hovered added line that a recorded turn wrote; nothing on any other line.
function AttributionMarker({
  hovered,
  store,
  target,
  actions,
  source,
}: {
  hovered: HoveredLine;
  store: AttributionStore;
  target: AttributionTarget | undefined;
  actions: { current: MarkerActions };
  source: { current: { source: AttributionSource | undefined; texts: ReadonlyMap<number, string> } };
}) {
  const t = useT();
  const line = useSyncExternalStore(hovered.subscribe, hovered.get, hovered.get);
  useSyncExternalStore(store.subscribe, store.getVersion, store.getVersion);
  const writers = target && line !== undefined ? store.writersOf(target, line, source.current.texts.get(line)) : [];
  const newest = writers[0];
  if (!newest) return null;
  const current = newest.sessionId === source.current.source?.sessionId;
  const handlers = {
    className: "cv-attribution-marker",
    "aria-label": t("attribution.marker"),
    onPointerEnter: (event: PointerEvent<HTMLElement>) => actions.current.show(writers, event.currentTarget),
    onPointerLeave: () => actions.current.go(),
    onFocus: (event: FocusEvent<HTMLElement>) => actions.current.show(writers, event.currentTarget, 0),
    onBlur: () => actions.current.go(),
  };
  const href = current ? undefined : sessionLink(newest.sessionId, newest.turnId);
  // A writer in another chat: its turn's link, which the host opens in the app.
  if (href)
    return <a {...handlers} aria-label={t("attribution.marker")} href={href} onClick={() => actions.current.now()} />;
  return (
    <button
      {...handlers}
      type="button"
      onClick={() => {
        actions.current.now();
        if (current) source.current.source?.reveal(newest.turnId);
      }}
    />
  );
}
