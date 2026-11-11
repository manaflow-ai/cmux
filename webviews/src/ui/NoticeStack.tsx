// The one queue and stack for toasts (leo-workspace design/notifications.md). A surface owns one
// queue (`createNoticeQueue`); anything may `show` into it, a host bridge included, since the queue
// lives outside React. NoticeStack draws it bottom centre over the surface, the native toast's
// placement (CmuxToastOverlayHost): newest at the bottom, at most three, a toast with the same id
// replacing the old one in its slot. A toast leaves after its time; the time stops while the pointer
// or focus is in the stack, or while the page is hidden, and starts again in full after.
//
// The same notice shown again (no id, the same kind and text: two clicks on one dead link) is one
// toast with a count, brought to the newest place with its time started over, never a second card.
//
// Two layouts. `list`: every toast in full, newest at the bottom. `stacked` (NoticeDeck.tsx): the
// newest in front and the older ones peeking above it as a compact deck, which spreads into the
// full list while the pointer or focus is in it.
//
// Timers: one setTimeout for the oldest running toast, armed only while the stack is visible and
// not held; cleared on every change, on hold, and on unmount. A toast with `duration: 0` never
// times out and arms nothing. With no toasts there is no timer and no listener but visibilitychange.
import { Fragment, useEffect, useMemo, useRef, useState, useSyncExternalStore, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { Notice, type NoticeAction, type NoticeKind, type NoticeProps } from "./Notice";
import {
  ANCHORS,
  anchorColumn,
  anchorPoint,
  anchorRow,
  DEFAULT_ANCHOR,
  type Anchor,
  type AnchorMemory,
  type Box,
} from "./anchors";
import { NoticeDeck, type DeckAlign, type DeckDrag, type DragFeel, type Flights } from "./NoticeDeck";

/** The native toast's default (CmuxToast `duration`). */
export const TOAST_MS = 6000;
/** At most this many toasts show; a newer one pushes the oldest out (CmuxToastStack `limit`). */
export const STACK_LIMIT = 3;

export interface ToastSpec extends Omit<NoticeProps, "kind" | "placement" | "onDismiss" | "id" | "count"> {
  /** The same id replaces the toast already showing under it. Default: a new id. */
  id?: string;
  kind?: NoticeKind;
  /** Milliseconds; 0 stays until closed. Default TOAST_MS. */
  duration?: number;
  /** What kind of toast it is, for where it shows: a toast dragged to an anchor is remembered
   *  under its group, and the next of that group shows there. Default: its kind. */
  group?: string;
  /** Where it shows. Default: where its group was last put, else the bottom. */
  anchor?: Anchor;
  /** An Undo (or any) action that also closes the toast. */
  actions?: readonly NoticeAction[];
  onClose?(reason: "timeout" | "closed" | "action" | "replaced"): void;
}

export interface NoticeEntry {
  spec: ToastSpec & { id: string };
  /** New on every show, so a replaced or reshown toast's time starts over. */
  version: number;
  /** How many times this same toast was shown while it was up: 1, then 2 for a repeat. */
  count: number;
  /** What makes two toasts the same one (kind and text), when their text is plain. */
  key?: string;
  /** Where it shows (anchors.ts). */
  anchor: Anchor;
}

/** A toast's group: what its anchor is remembered under. */
export function toastGroup(spec: ToastSpec): string {
  return spec.group ?? spec.kind ?? "toast";
}

/** Two toasts are the same one when their kind, title and message are the same plain text. */
export function toastKey(spec: ToastSpec): string | undefined {
  const { title, message } = spec;
  const plain = (value: ReactNode) => value === undefined || value === null || typeof value === "string";
  if (!plain(title) || !plain(message) || (!title && !message)) return undefined;
  return JSON.stringify([spec.kind ?? "toast", title ?? "", message ?? ""]);
}

export interface NoticeQueue {
  show(spec: ToastSpec): string;
  close(id: string, reason?: "timeout" | "closed" | "action"): void;
  /** Puts a showing toast at `anchor` and remembers it for its group. */
  move(id: string, anchor: Anchor): void;
  snapshot(): readonly NoticeEntry[];
  subscribe(listener: () => void): () => void;
}

export function createNoticeQueue(limit = STACK_LIMIT, { anchors }: { anchors?: AnchorMemory } = {}): NoticeQueue {
  // At least one: a limit of 0 would report every toast replaced and still keep it.
  const keep = Math.max(1, limit);
  let entries: readonly NoticeEntry[] = [];
  let next = 0;
  let shown = 0;
  const listeners = new Set<() => void>();
  const emit = () => {
    for (const listener of listeners) listener();
  };
  return {
    show(spec) {
      const key = toastKey(spec);
      let id = spec.id ?? undefined;
      let at = id === undefined ? -1 : entries.findIndex((entry) => entry.spec.id === id);
      // No id: the same toast still up takes the repeat.
      if (id === undefined && key !== undefined) {
        at = entries.findIndex((entry) => entry.key === key);
        if (at >= 0) id = entries[at]!.spec.id;
      }
      // A generated id skips any id showing, so it never replaces a caller's `toast-1`.
      if (id === undefined) {
        do id = `toast-${++next}`;
        while (entries.some((entry) => entry.spec.id === id));
      }
      const old = at >= 0 ? entries[at] : undefined;
      const repeat = old !== undefined && key !== undefined && old.key === key;
      // A repeat stays where it was put; a new toast goes where its group was last put.
      const anchor =
        spec.anchor ?? (repeat ? old.anchor : undefined) ?? anchors?.get(toastGroup(spec)) ?? DEFAULT_ANCHOR;
      const entry: NoticeEntry = {
        spec: { ...spec, id },
        version: ++shown,
        count: repeat ? old.count + 1 : 1,
        key,
        anchor,
      };
      // The queue changes before any onClose runs, so a callback that shows or closes a toast
      // works on the queue as it now is, not on an index this call has already read.
      let left: readonly NoticeEntry[];
      if (repeat) {
        // The same toast again: it counts, and comes to the newest place. Nothing left.
        left = [];
        entries = [...entries.filter((_, index) => index !== at), entry];
      } else if (old) {
        left = [old];
        entries = entries.map((item, index) => (index === at ? entry : item));
      } else {
        const kept = [...entries, entry];
        const evicted = Math.max(0, kept.length - keep);
        left = kept.slice(0, evicted);
        entries = kept.slice(evicted);
      }
      for (const gone of left) gone.spec.onClose?.("replaced");
      emit();
      return id;
    },
    close(id, reason = "closed") {
      const entry = entries.find((item) => item.spec.id === id);
      if (!entry) return;
      entries = entries.filter((item) => item !== entry);
      entry.spec.onClose?.(reason);
      emit();
    },
    move(id, anchor) {
      const at = entries.findIndex((item) => item.spec.id === id);
      if (at < 0) return;
      const entry = entries[at]!;
      anchors?.set(toastGroup(entry.spec), anchor);
      if (entry.anchor === anchor) return;
      entries = entries.map((item, index) => (index === at ? { ...item, anchor } : item));
      emit();
    },
    snapshot: () => entries,
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };
}

const systemNow = () => Date.now();
/** Arms one timeout and returns its cancel. */
export type ArmTimer = (fire: () => void, ms: number) => () => void;
const systemTimer: ArmTimer = (fire, ms) => {
  // wakeup-allow: one timer for the next toast to time out; cancelled on any change, hold or unmount
  const timer = setTimeout(fire, ms);
  return () => clearTimeout(timer);
};

const subscribeVisibility = (listener: () => void) => {
  document.addEventListener("visibilitychange", listener);
  return () => document.removeEventListener("visibilitychange", listener);
};
const pageVisible = () => document.visibilityState !== "hidden";
const visibleOnServer = () => true;

function usePageVisible(): boolean {
  return useSyncExternalStore(subscribeVisibility, pageVisible, visibleOnServer);
}

export type StackLayout = "list" | "stacked";

export function NoticeStack({
  queue,
  dismissLabel,
  layout = "list",
  align = "center",
  drag: feel,
  topHost,
  className,
  now = systemNow,
  arm = systemTimer,
}: {
  queue: NoticeQueue;
  /** The ×'s accessible name ("Dismiss"). */
  dismissLabel: string;
  /** `list`: every toast in full, newest at the bottom; `stacked`: a deck, newest in front. */
  layout?: StackLayout;
  /** Where the bottom anchor's deck stands across its surface (the gallery's compared option). */
  align?: DeckAlign;
  /** Stacked only: toasts drag to any of the six anchors (anchors.ts), with this feel. */
  drag?: DragFeel;
  /** Where the top anchors' decks are drawn (a box at the surface's top edge). Without it they
   *  hang from the top of the stack's own containing block. */
  topHost?: HTMLElement | null;
  className?: string;
  /** For tests: the clock and the timer. */
  now?: () => number;
  arm?: ArmTimer;
}) {
  const entries = useSyncExternalStore(queue.subscribe, queue.snapshot, queue.snapshot);
  const visible = usePageVisible();
  const [hovered, setHovered] = useState(false);
  const [focused, setFocused] = useState(false);
  // A toast held in a drag, and the anchor it would settle at.
  const [dragging, setDragging] = useState<{ nearest?: Anchor } | undefined>(undefined);
  // Stacked: each deck says whether it is held (a top deck is drawn in `topHost`, outside this
  // element, so this element's hover and focus cannot say it).
  const [deckHolds, setDeckHolds] = useState<ReadonlySet<Anchor>>(() => new Set());
  const holdOf = useMemo(
    () =>
      new Map(
        ANCHORS.map((anchor) => [
          anchor,
          (on: boolean) =>
            setDeckHolds((current) => {
              if (current.has(anchor) === on) return current;
              const next = new Set(current);
              if (on) next.add(anchor);
              else next.delete(anchor);
              return next;
            }),
        ]),
      ),
    [],
  );
  const pointed = layout === "stacked" ? deckHolds.size > 0 : hovered || focused;
  const held = pointed || dragging !== undefined || !visible;
  const stack = useRef<HTMLDivElement>(null);
  const top = useRef<HTMLDivElement>(null);
  const flights = useMemo<Flights>(() => new Map(), []);
  // A toast removed from under the pointer or focus (its × or Undo) sends no leave or blur: read the
  // stack's real state whenever the toasts change, so the hold never sticks.
  useEffect(() => {
    const element = stack.current;
    if (!element || layout === "stacked") return;
    setHovered(element.matches(":hover"));
    setFocused(element.contains(document.activeElement));
  }, [entries, layout]);
  // When each toast's time started: reset while held, so leaving the stack gives the full time again.
  const started = useMemo(() => new Map<string, { version: number; at: number }>(), []);

  useEffect(() => {
    if (held) {
      started.clear();
      return;
    }
    const t = now();
    let soonest: { id: string; due: number } | undefined;
    for (const { spec, version } of entries) {
      const duration = spec.duration ?? TOAST_MS;
      if (duration <= 0) continue;
      const mark = started.get(spec.id);
      const at = mark && mark.version === version ? mark.at : t;
      started.set(spec.id, { version, at });
      const due = at + duration;
      if (!soonest || due < soonest.due) soonest = { id: spec.id, due };
    }
    for (const id of started.keys()) if (!entries.some((entry) => entry.spec.id === id)) started.delete(id);
    if (!soonest) return;
    const { id, due } = soonest;
    return arm(() => queue.close(id, "timeout"), Math.max(0, due - t));
  }, [entries, held, queue, started, now, arm]);

  const draw = ({ spec, count }: NoticeEntry) => (
    <Notice
      {...spec}
      kind={spec.kind ?? "toast"}
      placement="stack"
      id={spec.id}
      count={count}
      actions={spec.actions?.map((action) => ({
        ...action,
        onSelect: () => {
          // Closed first, so an action that shows a follow-up under the same id keeps it.
          queue.close(spec.id, "action");
          action.onSelect?.();
        },
      }))}
      onDismiss={() => queue.close(spec.id, "closed")}
      dismissLabel={dismissLabel}
    />
  );

  // The surface toasts rest in: from the top anchors' edge to the stack's own line, its width.
  const box = (): Box => {
    const line = stack.current?.getBoundingClientRect();
    const head = top.current?.getBoundingClientRect();
    if (!line) return { left: 0, top: 0, width: 0, height: 0 };
    const upper = head && head.top < line.bottom ? head.top : line.top;
    return { left: line.left, top: upper, width: line.width, height: Math.max(0, line.bottom - upper) };
  };
  const deckDrag: DeckDrag | undefined =
    layout === "stacked" && feel
      ? {
          feel,
          box,
          hold: (on, nearest) => setDragging(on ? { nearest } : undefined),
          release: (id, release) => {
            if (release.kind === "dismiss") {
              flights.delete(id);
              queue.close(id, "closed");
              return;
            }
            const entry = queue.snapshot().find((item) => item.spec.id === id);
            if (entry?.anchor === release.anchor) flights.delete(id);
            queue.move(id, release.anchor);
          },
        }
      : undefined;
  // One list per anchor, new only when that anchor's toasts change, so a toast coming or going at
  // one anchor leaves the other decks (and their hover) alone.
  const lastByAnchor = useRef(new Map<Anchor, readonly NoticeEntry[]>());
  const byAnchor = useMemo(() => {
    const next = new Map<Anchor, readonly NoticeEntry[]>();
    for (const anchor of ANCHORS) {
      const here = entries.filter((entry) => entry.anchor === anchor);
      const before = lastByAnchor.current.get(anchor);
      const same = before?.length === here.length && here.every((entry, index) => entry === before[index]);
      next.set(anchor, same && before ? before : here);
    }
    lastByAnchor.current = next;
    return next;
  }, [entries]);
  const deckAt = (anchor: Anchor) => {
    const here = byAnchor.get(anchor) ?? [];
    return (
      <div
        key={anchor}
        className="ui-notice-anchor"
        data-anchor={anchor}
        data-row={anchorRow(anchor)}
        data-column={anchor === "bottom" && align === "end" ? "end" : anchorColumn(anchor)}
      >
        <NoticeDeck
          entries={here}
          draw={draw}
          edge={anchorRow(anchor)}
          drag={deckDrag}
          flights={flights}
          onHold={holdOf.get(anchor)}
        />
      </div>
    );
  };
  const ghosts =
    feel === "ghosts" && dragging
      ? (() => {
          const line = stack.current?.getBoundingClientRect();
          const area = box();
          if (!line) return null;
          return ANCHORS.map((anchor) => {
            const point = anchorPoint(anchor, area);
            return (
              <span
                key={anchor}
                className="ui-notice-anchor-ghost"
                data-anchor={anchor}
                data-near={dragging.nearest === anchor ? "" : undefined}
                style={{ left: point.x - line.left, top: point.y - line.top }}
              />
            );
          });
        })()
      : null;
  const topDecks = (
    <div ref={top} className="ui-notice-stack-top" data-layout="stacked">
      {ANCHORS.filter((anchor) => anchorRow(anchor) === "top").map(deckAt)}
    </div>
  );

  return (
    <div
      ref={stack}
      className={className ? `ui-notice-stack ${className}` : "ui-notice-stack"}
      data-layout={layout}
      data-align={layout === "stacked" ? align : undefined}
      data-dragging={dragging ? "" : undefined}
      onPointerEnter={() => setHovered(true)}
      onPointerLeave={() => setHovered(false)}
      onFocus={() => setFocused(true)}
      onBlur={(event) => {
        if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setFocused(false);
      }}
    >
      {layout === "stacked" ? (
        <>
          {ANCHORS.filter((anchor) => anchorRow(anchor) === "bottom").map(deckAt)}
          {topHost ? createPortal(topDecks, topHost) : topDecks}
          {ghosts}
        </>
      ) : (
        entries.map((entry) => <Fragment key={entry.spec.id}>{draw(entry)}</Fragment>)
      )}
    </div>
  );
}
