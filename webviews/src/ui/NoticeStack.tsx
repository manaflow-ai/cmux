// The one queue and stack for toasts (leo-workspace design/notifications.md). A surface owns one
// queue (`createNoticeQueue`); anything may `show` into it, a host bridge included, since the queue
// lives outside React. NoticeStack draws it bottom centre over the surface, the native toast's
// placement (CmuxToastOverlayHost): newest at the bottom, at most three, a toast with the same id
// replacing the old one in its slot. A toast leaves after its time; the time stops while the pointer
// or focus is in the stack, or while the page is hidden, and starts again in full after.
//
// Timers: one setTimeout for the oldest running toast, armed only while the stack is visible and
// not held; cleared on every change, on hold, and on unmount. A toast with `duration: 0` never
// times out and arms nothing. With no toasts there is no timer and no listener but visibilitychange.
import { useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { Notice, type NoticeAction, type NoticeKind, type NoticeProps } from "./Notice";

/** The native toast's default (CmuxToast `duration`). */
export const TOAST_MS = 6000;
/** At most this many toasts show; a newer one pushes the oldest out (CmuxToastStack `limit`). */
export const STACK_LIMIT = 3;

export interface ToastSpec extends Omit<NoticeProps, "kind" | "placement" | "onDismiss" | "id"> {
  /** The same id replaces the toast already showing under it. Default: a new id. */
  id?: string;
  kind?: NoticeKind;
  /** Milliseconds; 0 stays until closed. Default TOAST_MS. */
  duration?: number;
  /** An Undo (or any) action that also closes the toast. */
  actions?: readonly NoticeAction[];
  onClose?(reason: "timeout" | "closed" | "action" | "replaced"): void;
}

export interface NoticeEntry {
  spec: ToastSpec & { id: string };
  /** New on every show, so a replaced or reshown toast's time starts over. */
  version: number;
}

export interface NoticeQueue {
  show(spec: ToastSpec): string;
  close(id: string, reason?: "timeout" | "closed" | "action"): void;
  snapshot(): readonly NoticeEntry[];
  subscribe(listener: () => void): () => void;
}

export function createNoticeQueue(limit = STACK_LIMIT): NoticeQueue {
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
      const id = spec.id ?? `toast-${++next}`;
      const at = entries.findIndex((entry) => entry.spec.id === id);
      const entry: NoticeEntry = { spec: { ...spec, id }, version: ++shown };
      // The queue changes before any onClose runs, so a callback that shows or closes a toast
      // works on the queue as it now is, not on an index this call has already read.
      let left: readonly NoticeEntry[];
      if (at >= 0) {
        left = [entries[at]!];
        entries = entries.map((old, index) => (index === at ? entry : old));
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

export function NoticeStack({
  queue,
  dismissLabel,
  now = systemNow,
  arm = systemTimer,
}: {
  queue: NoticeQueue;
  /** The ×'s accessible name ("Dismiss"). */
  dismissLabel: string;
  /** For tests: the clock and the timer. */
  now?: () => number;
  arm?: ArmTimer;
}) {
  const entries = useSyncExternalStore(queue.subscribe, queue.snapshot, queue.snapshot);
  const visible = usePageVisible();
  const [hovered, setHovered] = useState(false);
  const [focused, setFocused] = useState(false);
  const held = hovered || focused || !visible;
  const stack = useRef<HTMLDivElement>(null);
  // A toast removed from under the pointer or focus (its × or Undo) sends no leave or blur: read the
  // stack's real state whenever the toasts change, so the hold never sticks.
  useEffect(() => {
    const element = stack.current;
    if (!element) return;
    setHovered(element.matches(":hover"));
    setFocused(element.contains(document.activeElement));
  }, [entries]);
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

  return (
    <div
      ref={stack}
      className="ui-notice-stack"
      onPointerEnter={() => setHovered(true)}
      onPointerLeave={() => setHovered(false)}
      onFocus={() => setFocused(true)}
      onBlur={(event) => {
        if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setFocused(false);
      }}
    >
      {entries.map(({ spec }) => (
        <Notice
          key={spec.id}
          {...spec}
          kind={spec.kind ?? "toast"}
          placement="stack"
          id={spec.id}
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
      ))}
    </div>
  );
}
