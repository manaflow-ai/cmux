// The one system for transient and attention UI in shared web (leo-workspace design/notifications.md):
// four kinds, one card, one queue.
//
// - `toast`: transient information or success, optional Undo; it leaves on its own (NoticeStack).
// - `warning`: stays until what it is about is resolved; inline or a banner.
// - `ask`: needs an answer; buttons, and an optional checkmark ("Ask me first") wired to a setting,
//   so an agent's permission-type card can default to doing the thing and still let the person ask.
// - `error`: something failed; Retry leads, always first and the one filled button. Never red slabs:
//   the kind shows in a small mark and the title, the card stays quiet glass (Leo 2026-10-29 on
//   recovery cards).
//
// A notice opens in one frame and may fade out (menus and popovers have no fade-in; rulings.md). It
// never moves the caret: it takes focus only when the person tabs into it. Escape inside it dismisses
// it when it can be dismissed. Native calls forward into the same card through the host's cards
// (toolCards) rather than drawing their own.
import { Checkbox } from "@base-ui/react/checkbox";
import { useId, type KeyboardEvent, type ReactNode } from "react";
import { Button } from "./Button";
import { cx } from "./cx";
import "./controls.css";
import "./notice.css";

export type NoticeKind = "toast" | "warning" | "ask" | "error";
/** inline: in the flow of its surface (above a composer, in a form); banner: across the top of a
 * page; stack: one of NoticeStack's toasts, over the surface. */
export type NoticePlacement = "inline" | "banner" | "stack";

export interface NoticeAction {
  id: string;
  label: string;
  onSelect?(): void;
  /** A link the host opens outside the page on the person's click (PageNavigation), drawn as a button. */
  href?: string;
  /** The one filled button. Without one, an ask fills its first action; other kinds fill none. */
  primary?: boolean;
  /** The button's tooltip: its scope, said nowhere else. */
  hint?: string;
  disabled?: boolean;
  /** A form's submit button (an ask with a field). */
  submit?: boolean;
}

/** The checkmark under an ask ("Ask me first", "Don't ask again"): a setting, so it is controlled. */
export interface NoticeCheck {
  label: string;
  checked: boolean;
  onCheckedChange(checked: boolean): void;
  hint?: string;
}

export interface NoticeProps {
  kind: NoticeKind;
  placement?: NoticePlacement;
  /** One short line. */
  title?: ReactNode;
  /** The sentence under the title, or the only line. */
  message?: ReactNode;
  /** Before the text: the kind's mark by default; a spinner while working. */
  leading?: ReactNode;
  /** An error's Retry: always the first button and the filled one. */
  retry?: { label: string; onRetry(): void; disabled?: boolean; hint?: string };
  actions?: readonly NoticeAction[];
  check?: NoticeCheck;
  /** The ×, and Escape while focus is inside. The × has no text, so `dismissLabel` names it. */
  onDismiss?(): void;
  dismissLabel?: string;
  /** Extra content between the text and the buttons (a field). */
  children?: ReactNode;
  className?: string;
  /** Forwarded for a host's checks and the stack's hover. */
  id?: string;
}

/** The buttons in their order: an error's Retry first, then the actions; which one is filled. */
export function noticeButtons(
  kind: NoticeKind,
  actions: readonly NoticeAction[] = [],
  retry?: NoticeProps["retry"],
): { action: NoticeAction; filled: boolean }[] {
  const all: NoticeAction[] = retry
    ? [
        {
          id: "retry",
          label: retry.label,
          onSelect: retry.onRetry,
          disabled: retry.disabled,
          hint: retry.hint,
          primary: true,
        },
      ]
    : [];
  for (const action of actions) all.push(retry ? { ...action, primary: false } : action);
  let filled = all.findIndex((action) => action.primary);
  if (filled < 0 && kind === "ask" && all.length > 0) filled = 0;
  return all.map((action, index) => ({ action, filled: index === filled }));
}

/** The role a notice of `kind` takes: an error interrupts, an ask is a group to answer, the rest are
 * polite status. */
export function noticeRole(kind: NoticeKind): "alert" | "group" | "status" {
  return kind === "error" ? "alert" : kind === "ask" ? "group" : "status";
}

export function Notice({
  kind,
  placement = "inline",
  title,
  message,
  leading,
  retry,
  actions,
  check,
  onDismiss,
  dismissLabel,
  children,
  className,
  id,
}: NoticeProps) {
  const titleId = useId();
  const messageId = useId();
  const buttons = noticeButtons(kind, actions, retry);
  const role = noticeRole(kind);
  const onKeyDown = (event: KeyboardEvent<HTMLElement>) => {
    if (event.key !== "Escape" || !onDismiss || event.defaultPrevented) return;
    event.preventDefault();
    event.stopPropagation();
    onDismiss();
  };
  const mark = leading ?? (kind === "toast" ? null : <NoticeMark kind={kind} />);
  return (
    // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- Escape closes the notice from its buttons, checkmark or field.
    <section
      id={id}
      className={cx("ui-notice ui-glass", className)}
      data-kind={kind}
      data-placement={placement}
      role={role}
      aria-live={role === "group" ? "polite" : undefined}
      aria-labelledby={title ? titleId : message ? messageId : undefined}
      aria-describedby={title && message ? messageId : undefined}
      onKeyDown={onKeyDown}
    >
      <div className="ui-notice-main">
        {mark && <span className="ui-notice-lead">{mark}</span>}
        <div className="ui-notice-text">
          {title && (
            <span className="ui-notice-title selectable" id={titleId}>
              {title}
            </span>
          )}
          {message && (
            <span className="ui-notice-message selectable" id={messageId}>
              {message}
            </span>
          )}
        </div>
      </div>
      {children && <div className="ui-notice-extra">{children}</div>}
      {(buttons.length > 0 || check) && (
        <div className="ui-notice-foot">
          {check && <NoticeCheckmark {...check} />}
          {buttons.length > 0 && (
            <div className="ui-notice-actions">
              {buttons.map(({ action, filled }) =>
                // A disabled link is drawn as its disabled button, so it neither focuses nor opens.
                action.href && !action.disabled ? (
                  // A link the host opens outside the page (PageNavigation), in the button's look.
                  <a
                    key={action.id}
                    className="ui-button ui-btn ui-notice-link"
                    data-variant={filled ? "solid" : "ghost"}
                    data-size="sm"
                    data-notice-action={action.id}
                    href={action.href}
                    /* tooltip-allow: the link names the action; the tooltip is its scope, shown nowhere else */
                    title={action.hint}
                    onClick={action.onSelect}
                  >
                    {action.label}
                  </a>
                ) : (
                  <Button
                    key={action.id}
                    type={action.submit ? "submit" : "button"}
                    variant={filled ? "solid" : "ghost"}
                    size="sm"
                    data-notice-action={action.id}
                    disabled={action.disabled}
                    /* tooltip-allow: the button names the action; the tooltip is its scope, shown nowhere else */
                    title={action.hint}
                    onClick={action.submit ? undefined : action.onSelect}
                  >
                    {action.label}
                  </Button>
                ),
              )}
            </div>
          )}
        </div>
      )}
      {/* Last in the tab order: an answer or Retry comes before closing. */}
      {onDismiss && (
        <Button
          variant="ghost"
          size="sm"
          icon
          className="ui-notice-dismiss"
          aria-label={dismissLabel}
          onClick={onDismiss}
        >
          <svg viewBox="0 0 12 12" width="12" height="12" aria-hidden="true">
            <path d="M3 3l6 6M9 3l-6 6" stroke="currentColor" strokeWidth="1.25" strokeLinecap="round" />
          </svg>
        </Button>
      )}
    </section>
  );
}

/** The checkmark: a small box and its label, the whole row a click target. */
function NoticeCheckmark({ label, checked, onCheckedChange, hint }: NoticeCheck) {
  return (
    // tooltip-allow: the label names the setting; the tooltip says what it changes
    <label className="ui-notice-check" title={hint}>
      <Checkbox.Root
        className="ui-notice-check-box"
        checked={checked}
        onCheckedChange={(next) => onCheckedChange(next)}
      >
        <Checkbox.Indicator className="ui-notice-check-mark">
          <svg viewBox="0 0 12 12" width="12" height="12" aria-hidden="true">
            <path
              d="M2.5 6.2 4.9 8.6 9.5 3.6"
              fill="none"
              stroke="currentColor"
              strokeWidth="1.5"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          </svg>
        </Checkbox.Indicator>
      </Checkbox.Root>
      <span>{label}</span>
    </label>
  );
}

/** The kind's small mark: a ring for an error, a triangle for a warning, a dot for an ask. */
export function NoticeMark({ kind }: { kind: NoticeKind }) {
  return (
    <svg className="ui-notice-mark" viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" data-kind={kind}>
      {kind === "error" ? (
        <>
          <circle cx="8" cy="8" r="6" fill="none" stroke="currentColor" strokeWidth="1.25" />
          <path d="M8 4.75v3.75M8 10.9v.35" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
        </>
      ) : kind === "warning" ? (
        <>
          <path d="M8 2.6 14 13H2Z" fill="none" stroke="currentColor" strokeWidth="1.25" strokeLinejoin="round" />
          <path d="M8 6.5v3M8 11.2v.3" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
        </>
      ) : (
        <circle cx="8" cy="8" r="3" fill="currentColor" />
      )}
    </svg>
  );
}
