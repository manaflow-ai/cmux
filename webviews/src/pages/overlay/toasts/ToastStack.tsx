// The app's toast stack (R96), drawn by the overlay page over the window (CmuxToastWebHost.swift):
// at most three, newest at the bottom, bottom center above `floor`. Each toast is the message, at most
// one action (Undo, Reopen, a custom one, or Details) and a close button, on the toast surface's glass
// (--surface-toast-*), opaque under Reduce Transparency through `.ui-glass`.
//
// The app owns which toasts show, their timers and their state (Details on, which Undo Cmd-Z runs);
// the stack draws them, moves them (useToastMotion) and sends the person's clicks and pointer back.
// It tells the app where its toasts are after every change, so the window takes clicks only there and
// keeps the chat clear of them (#36969).
import { useCallback, useEffect, useLayoutEffect, useRef } from "react";
import { cx } from "../../../ui/cx";
import { type DetailCopy, plainDetail } from "./detailCopy";
import type { ToastRect, ToastState } from "./types";
import { layoutPlace, useToastMotion } from "./useToastMotion";
import "../../../ui/glass/glass.css";
import "./toasts.css";

/** The words the stack draws itself (generated/strings.json); the messages and action titles come from the app. */
export interface ToastWords {
  t(key: string): string;
  format(key: string, ...args: string[]): string;
}

export interface ToastStackProps {
  toasts: readonly ToastState[];
  /** The stack's lowest bottom edge, CSS px from the page's bottom. */
  floor: number;
  words: ToastWords;
  onAction(serial: number): void;
  onClose(serial: number): void;
  onHover(serial: number, hovered: boolean): void;
  /** Where the toasts rest (and where fading ones still draw), after every change. */
  onLayout(rects: ToastRect[], fading: ToastRect[]): void;
  /**
   * The app draws the window's glass under each toast (the overlay page, which cannot blur the window
   * under it): the toast draws only its contents and its shadow. Off (the gallery): the page's own glass.
   */
  nativeGlass?: boolean;
}

const rectOf = (serial: number, place: { x: number; y: number; w: number; h: number }): ToastRect => ({
  serial,
  x: Math.round(place.x * 100) / 100,
  y: Math.round(place.y * 100) / 100,
  w: Math.round(place.w * 100) / 100,
  h: Math.round(place.h * 100) / 100,
});

export function ToastStack({
  toasts,
  floor,
  words,
  onAction,
  onClose,
  onHover,
  onLayout,
  nativeGlass = false,
}: ToastStackProps) {
  const list = useRef<HTMLDivElement>(null);
  const sent = useRef("");
  const leavingUndrawn = useRef(false);
  const report = useCallback(() => {
    const root = list.current;
    // A toast that ended is not drawn fading yet: reported now, the stack would read as empty and the
    // host would take the page off before the fade shows (review 1 of #37289).
    if (!root || leavingUndrawn.current) return;
    const rects: ToastRect[] = [];
    const fading: ToastRect[] = [];
    for (const element of root.querySelectorAll<HTMLElement>("[data-toast-serial]")) {
      const rect = rectOf(Number(element.dataset.toastSerial), layoutPlace(element));
      (element.dataset.toastExiting === undefined ? rects : fading).push(rect);
    }
    const key = JSON.stringify([rects, fading]);
    if (key === sent.current) return;
    sent.current = key;
    onLayout(rects, fading);
  }, [onLayout]);
  const exiting = useToastMotion(list, toasts, report, leavingUndrawn);

  // The page resized (the window did) or a toast's text wrapped again: say where they are now.
  useEffect(() => {
    const root = list.current;
    if (!root || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(() => report());
    observer.observe(root);
    return () => observer.disconnect();
  }, [report]);
  useLayoutEffect(report, [floor, report]);

  // The toasts in order, with each fading one where it was among them.
  const items: { key: string; toast: ToastState; exiting: boolean }[] = toasts.map((toast) => ({
    key: String(toast.serial),
    toast,
    exiting: false,
  }));
  for (const gone of exiting)
    items.splice(Math.min(gone.index, items.length), 0, {
      key: `exit-${gone.toast.serial}`,
      toast: gone.toast,
      exiting: true,
    });
  return (
    <div ref={list} className="cmux-toasts" style={{ bottom: `${floor}px` }} data-count={toasts.length}>
      {items.map((item) =>
        item.exiting ? (
          <Toast key={item.key} toast={item.toast} words={words} nativeGlass={nativeGlass} exiting />
        ) : (
          <Toast
            key={item.key}
            toast={item.toast}
            words={words}
            nativeGlass={nativeGlass}
            onAction={onAction}
            onClose={onClose}
            onHover={onHover}
          />
        ),
      )}
    </div>
  );
}

function Toast({
  toast,
  words,
  nativeGlass,
  exiting = false,
  onAction,
  onClose,
  onHover,
}: {
  toast: ToastState;
  words: ToastWords;
  nativeGlass: boolean;
  exiting?: boolean;
  onAction?(serial: number): void;
  onClose?(serial: number): void;
  onHover?(serial: number, hovered: boolean): void;
}) {
  const { serial, action, detail, showsDetails } = toast;
  const open = showsDetails && detail !== undefined;
  const copy: DetailCopy | undefined = open ? plainDetail(detail, words.t) : undefined;
  const actionTitle = action?.revealsDetails && showsDetails ? words.t("overlay.toasts.hideDetails") : action?.title;
  return (
    <section
      className={nativeGlass ? "cmux-toast" : "cmux-toast ui-glass"}
      data-native-glass={nativeGlass ? "true" : undefined}
      aria-label={toast.message}
      data-toast-serial={serial}
      data-toast-id={toast.id}
      data-toast-exiting={exiting ? "true" : undefined}
      data-open={open || undefined}
      onPointerEnter={exiting ? undefined : () => onHover?.(serial, true)}
      onPointerLeave={exiting ? undefined : () => onHover?.(serial, false)}
    >
      <div className="cmux-toast-row">
        {/* tooltip-allow: the message's detail, shown in the toast only while Details is on */}
        <p className="cmux-toast-message" title={open ? toast.message : detail}>
          {toast.message}
        </p>
        {action && actionTitle && (
          <button
            type="button"
            className="cmux-toast-action"
            data-on={open || undefined}
            aria-expanded={action.revealsDetails ? open : undefined}
            /* tooltip-allow: Cmd-Z runs this Undo; the key is said nowhere else */
            title={toast.showsUndoKey ? `${action.title} ⌘Z` : undefined}
            aria-keyshortcuts={toast.showsUndoKey ? "Meta+Z" : undefined}
            onClick={() => onAction?.(serial)}
            tabIndex={exiting ? -1 : undefined}
          >
            <span>{actionTitle}</span>
            {open && (
              <svg className="cmux-toast-chevron" viewBox="0 0 12 12" width="12" height="12" aria-hidden="true">
                <path
                  d="M3 7.5 6 4.5l3 3"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="1.5"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                />
              </svg>
            )}
          </button>
        )}
        {toast.closable && (
          <button
            type="button"
            className="cmux-toast-close"
            aria-label={words.t("overlay.toasts.dismiss")}
            onClick={() => onClose?.(serial)}
            tabIndex={exiting ? -1 : undefined}
          >
            <svg viewBox="0 0 12 12" width="12" height="12" aria-hidden="true">
              <path d="M3 3l6 6M9 3l-6 6" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
            </svg>
          </button>
        )}
      </div>
      {copy && (
        <div className={cx("cmux-toast-detail", "selectable")}>
          <p className="cmux-toast-detail-text">{copy.text}</p>
          {copy.code && (
            // tooltip-allow: the raw reason, word for word, for a bug report
            <p className="cmux-toast-detail-code" title={detail}>
              {words.format("overlay.toasts.detail.errorCode", copy.code)}
            </p>
          )}
        </div>
      )}
    </section>
  );
}
