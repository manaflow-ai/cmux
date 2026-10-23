import React, { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { toolIcon } from "./conversation/ToolRow";
import { useT } from "./i18n";
import type { AcpmuxPermission } from "./model";
import {
  alwaysAllowScope,
  commandPreview,
  permissionAnswers,
  permissionCommand,
  permissionDetail,
  permissionKeyAction,
  permissionOptionKind,
  permissionScopeText,
  permissionTitle,
  type PermissionKeyAction,
} from "./permissions/prompt";
import { SHORTCUT_ACTIONS, useShortcut } from "./shortcuts";

export { permissionOptionKind } from "./permissions/prompt";

type PermissionOption = AcpmuxPermission["options"][number];

/** The single card frame used by legacy ACP asks and grouped tool permissions. */
type PermissionCardFrameProps = {
  title?: string;
  ariaLabel?: string;
  leading?: React.ReactNode;
  children: React.ReactNode;
  className?: string;
};

export const PermissionCardFrame = React.forwardRef<HTMLFieldSetElement, PermissionCardFrameProps>(
  function PermissionCardFrame({ title, ariaLabel, leading, children, className }, ref) {
    const titleId = React.useId();
    return (
      <fieldset
        ref={ref}
        className={`acpmux-permission-card${className ? ` ${className}` : ""}`}
        aria-labelledby={title ? titleId : undefined}
        aria-label={!title ? ariaLabel : undefined}
      >
        {title && (
          <div className="acpmux-permission-card-heading">
            {leading && <span className="acpmux-permission-card-leading">{leading}</span>}
            <strong id={titleId}>{title}</strong>
          </div>
        )}
        {children}
      </fieldset>
    );
  },
);

/** Shared action button so grouped and legacy cards present the same localized label and key hint. */
export function PermissionActionButton({
  label,
  shortcut,
  description,
  ...props
}: React.ButtonHTMLAttributes<HTMLButtonElement> & { label: string; shortcut?: string; description?: string }) {
  const { className, ...buttonProps } = props;
  return (
    <button
      {...buttonProps}
      className={className}
      type="button"
      aria-label={label}
      aria-keyshortcuts={shortcut || undefined}
    >
      <span className="acpmux-permission-action-label">{label}</span>
      {description && <span className="acpmux-permission-action-description">{description}</span>}
      {shortcut && <kbd className="acpmux-permission-action-shortcut">{shortcut}</kbd>}
    </button>
  );
}

/// A permission ask as Claude Code desktop draws it: a glass card with the tool's glyph and what the
/// call does as its title, the command clamped to its first line ("Show full command" opens all of
/// it), and Allow once, Always allow and Deny, each shown only when the agent offered that kind
/// (permissions/prompt.ts). Deny opens a field for what the agent should do instead, sent with the
/// deny through `onDenyWithFeedback`. Keys 1, 2 and 3, Return (Allow once) and Esc (Deny, or close
/// the field) answer while this card is the prompt and nothing else has the keyboard.
export function PermissionCard({
  permission,
  onAnswer,
  onDenyWithFeedback,
  harness,
  focusComposer,
  shortcuts = true,
  waiting = 0,
}: {
  permission: AcpmuxPermission;
  onAnswer(optionId: string): void;
  /// Denies with `optionId`, then gives the agent `text` (empty: only denies). False when acpmux
  /// refused the deny: the field stays, with what was typed.
  onDenyWithFeedback?(optionId: string, text: string): Promise<boolean>;
  harness?: string;
  focusComposer?: () => void;
  /// False while another ask takes the permission shortcuts (a waiting permission group,
  /// permissionKeys.ts `cardTakesShortcuts`): the card then neither answers its keys nor shows them.
  shortcuts?: boolean;
  /// More asks waiting behind this one, answered after it.
  waiting?: number;
}) {
  const t = useT();
  const command = permissionCommand(permission);
  const preview = useMemo(() => commandPreview(command), [command]);
  const title = permissionTitle(permission, t);
  const detail = permissionDetail(permission);
  const {
    allowOnce,
    allowAlways,
    deny: denyOption,
    others,
  } = useMemo(() => permissionAnswers(permission.options), [permission.options]);
  const alwaysScope = allowAlways && alwaysAllowScope(permission, allowAlways);
  const scopeText = permissionScopeText(permission, t);
  const scopeId = React.useId();
  const feedback = Boolean(onDenyWithFeedback && permission.pending && denyOption);
  const claude = harness === "claude" || harness?.startsWith("claude-");
  /// The ask whose full command is open: a new ask opens collapsed.
  const [expanded, setExpanded] = useState<string>();
  const showFull = expanded === permission.permissionId;
  const fullId = React.useId();
  // A one-line command longer than the two lines the preview holds is cut off: measured, so "Show
  // full command" is offered whenever the preview does not show all of it.
  const previewRef = useRef<HTMLElement>(null);
  const [clamped, setClamped] = useState(false);
  useLayoutEffect(() => {
    const element = previewRef.current;
    if (!element) return;
    const measure = () => setClamped(element.scrollHeight > element.clientHeight + 1);
    measure();
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    return () => observer.disconnect();
  }, [preview.line, showFull]);
  /// The field's text while it is open, for the ask it opened on; `sending` while its deny goes.
  const [draft, setDraft] = useState<{ permissionId: string; text: string; sending?: boolean }>();
  const writing = draft?.permissionId === permission.permissionId ? draft : undefined;
  const field = useRef<HTMLTextAreaElement>(null);
  // Opening it again (Deny, its key, the deny shortcut) keeps what is typed.
  const openFeedback = () => {
    if (!writing) setDraft({ permissionId: permission.permissionId, text: "" });
  };
  const fieldOpen = writing !== undefined;
  // Opened by the person's own click or key, so the field takes the keyboard.
  useEffect(() => {
    if (fieldOpen) field.current?.focus();
  }, [fieldOpen]);
  const group = useRef<HTMLFieldSetElement>(null);
  /// Set when the field closes without sending: the keyboard goes back to Deny.
  const backToOpener = useRef(false);
  useEffect(() => {
    if (fieldOpen || !backToOpener.current) return;
    backToOpener.current = false;
    group.current?.querySelector<HTMLElement>("[data-feedback-opener]")?.focus();
  }, [fieldOpen]);
  const closeFeedback = () => {
    if (writing?.sending) return;
    backToOpener.current = true;
    setDraft(undefined);
  };
  // The ask a key already answered: held keys repeat, and a second key can land before the
  // snapshot clears the ask, so the keyboard answers each ask once. A click always answers (an
  // answer acpmux never heard can be given again).
  const answered = useRef<string | undefined>(undefined);
  // After an answer the keyboard goes back to the composer, so a stray key never answers the next
  // ask in line.
  const answer = (option: PermissionOption) => {
    onAnswer(option.id);
    focusComposer?.();
  };
  const answerByKey = (option: PermissionOption) => {
    if (answered.current === permission.permissionId) return;
    answered.current = permission.permissionId;
    answer(option);
  };
  /// Deny: the field for what to do instead when the pane can send it, else the deny itself.
  const deny = (byKey = false) => {
    if (!denyOption) return;
    if (feedback) openFeedback();
    else if (byKey) answerByKey(denyOption);
    else answer(denyOption);
  };
  /// The keys' and the shortcuts' actions, read at the time of the key.
  const act = useRef<(action: PermissionKeyAction) => boolean>(() => false);
  useLayoutEffect(() => {
    act.current = (action) => {
      if (action === "closeFeedback") {
        if (!writing || writing.sending) return false;
        closeFeedback();
        return true;
      }
      if (answered.current === permission.permissionId) return false;
      if (action === "deny") {
        if (!denyOption) return false;
        deny(true);
        return true;
      }
      const option = action === "allow_once" ? allowOnce : allowAlways;
      if (!option) return false;
      answerByKey(option);
      return true;
    };
  });
  const allowOnceShortcut = useShortcut(SHORTCUT_ACTIONS.permissionAllowOnce);
  const allowChatShortcut = useShortcut(SHORTCUT_ACTIONS.permissionAllowChat);
  const denyShortcut = useShortcut(SHORTCUT_ACTIONS.permissionDeny);
  const active = permission.pending && shortcuts;
  // The keys go to the page, not to the card: with nothing focused the card is still the prompt.
  // Capture, so a digit is taken before the composer's typing-anywhere listener (composerFocus.ts)
  // puts it in the prompt; permissionKeyAction leaves any key a field, menu or button owns.
  useEffect(() => {
    if (!active) return;
    const onKey = (event: KeyboardEvent) => {
      const action = permissionKeyAction(event, group.current, fieldOpen);
      if (!action || !act.current(action)) return;
      event.preventDefault();
      event.stopPropagation();
    };
    document.addEventListener("keydown", onKey, true);
    return () => document.removeEventListener("keydown", onKey, true);
  }, [active, fieldOpen]);
  // The app's permission shortcuts (⌥⌘1, ⌥⌘2, ⌥⌘3) arrive as page events.
  useEffect(() => {
    if (!active) return;
    const events = [
      ["cmux-acpmux-permissionAllowOnce", "allow_once"],
      ["cmux-acpmux-permissionAllowChat", "allow_always"],
      ["cmux-acpmux-permissionDeny", "deny"],
    ] as const;
    const handlers = events.map(([event, action]) => {
      const handler = () => void act.current(action);
      window.addEventListener(event, handler);
      return [event, handler] as const;
    });
    return () => handlers.forEach(([event, handler]) => window.removeEventListener(event, handler));
  }, [active]);
  const sendFeedback = async (text: string) => {
    if (!denyOption || !onDenyWithFeedback || writing?.sending || answered.current === permission.permissionId) return;
    const permissionId = permission.permissionId;
    answered.current = permissionId;
    setDraft({ permissionId, text, sending: true });
    if (await onDenyWithFeedback(denyOption.id, text.trim())) {
      setDraft(undefined);
      // The keyboard goes back to the composer, as a plain deny's does.
      focusComposer?.();
      return;
    }
    // Refused (answered elsewhere, or the connection dropped): the field stays with its text.
    answered.current = undefined;
    setDraft({ permissionId, text });
    field.current?.focus();
  };

  return (
    <PermissionCardFrame ref={group} className="acpmux-permission-ask ui-glass" ariaLabel={title}>
      <div className="acpmux-permission-request" data-harness={harness || undefined}>
        <div className="acpmux-permission-request-head">
          <span className="acpmux-permission-request-icon" aria-hidden="true">
            {toolIcon(permission.kind ?? (command ? "execute" : undefined))}
          </span>
          <div className="acpmux-permission-request-label">{title}</div>
        </div>
        {waiting > 0 && <p className="acpmux-permission-waiting">{t("permission.moreWaiting", { n: waiting })}</p>}
        {detail && <p className="acpmux-permission-request-description">{detail}</p>}
        {command && (
          <div className="acpmux-permission-command" data-expanded={showFull || undefined}>
            {showFull ? (
              <pre id={fullId} className="acpmux-permission-command-full">
                <code>{command}</code>
              </pre>
            ) : (
              <div className="acpmux-permission-command-preview">
                <code ref={previewRef}>{preview.line}</code>
              </div>
            )}
            {(preview.more || clamped || showFull) && (
              <button
                type="button"
                className="acpmux-permission-command-toggle"
                aria-expanded={showFull}
                aria-controls={showFull ? fullId : undefined}
                onClick={() => setExpanded(showFull ? undefined : permission.permissionId)}
              >
                {showFull ? t("permission.hideFullCommand") : t("permission.showFullCommand")}
              </button>
            )}
          </div>
        )}
      </div>
      {!writing && (
        <div className="acpmux-permission-buttons">
          {allowOnce && (
            <PermissionActionButton
              label={t("permission.allowOnce")}
              description={scopeText}
              aria-describedby={scopeText ? scopeId : undefined}
              shortcut={shortcuts ? allowOnceShortcut : undefined}
              className="acpmux-permission-primary"
              onClick={() => answer(allowOnce)}
            />
          )}
          {allowAlways && (
            <PermissionActionButton
              label={
                permissionOptionKind(allowAlways) === "allow_chat"
                  ? t("permission.allowChat")
                  : t("permission.alwaysAllow")
              }
              shortcut={shortcuts ? allowChatShortcut : undefined}
              title={alwaysScope}
              description={alwaysScope || scopeText}
              aria-describedby={scopeText ? scopeId : undefined}
              onClick={() => answer(allowAlways)}
            />
          )}
          {denyOption && (
            <PermissionActionButton
              label={t("permission.deny")}
              shortcut={shortcuts ? denyShortcut : undefined}
              aria-describedby={scopeText ? scopeId : undefined}
              className="acpmux-permission-deny"
              data-feedback-opener=""
              onClick={() => deny()}
            />
          )}
        </div>
      )}
      {!writing && scopeText && (
        <p id={scopeId} className="acpmux-permission-scope" data-scope-kind={permission.scope?.kind} aria-label={scopeText}>
          {scopeText}
        </p>
      )}
      {!writing && alwaysScope && <p className="acpmux-permission-always-scope">{alwaysScope}</p>}
      {!writing && others.length > 0 && (
        <div className="acpmux-permission-others">
          {others.map((option) => (
            <button key={option.id} type="button" title={option.description} onClick={() => answer(option)}>
              {option.name}
            </button>
          ))}
        </div>
      )}
      {writing && (
        <form
          className="acpmux-permission-feedback"
          onSubmit={(event) => {
            event.preventDefault();
            void sendFeedback(writing.text);
          }}
        >
          <textarea
            ref={field}
            rows={2}
            aria-label={claude ? t("permission.claude.feedbackPlaceholder") : t("permission.feedbackPlaceholder")}
            placeholder={claude ? t("permission.claude.feedbackPlaceholder") : t("permission.feedbackPlaceholder")}
            value={writing.text}
            readOnly={writing.sending}
            onChange={(event) => setDraft({ permissionId: permission.permissionId, text: event.target.value })}
            // ui-allow: a text field's own Return (send) beside Shift-Return (new line), as the composer's.
            onKeyDown={(event) => {
              // An input method keeps its Return: WebKit can end the composition before the Return's
              // keydown, which then only says keyCode 229.
              if (event.key !== "Enter" || event.shiftKey) return;
              if (event.nativeEvent.isComposing || event.keyCode === 229) return;
              event.preventDefault();
              void sendFeedback(writing.text);
            }}
          />
          <div className="acpmux-permission-feedback-actions">
            <button type="button" disabled={writing.sending} onClick={closeFeedback}>
              {t("permission.feedbackCancel")}
            </button>
            <button type="submit" className="acpmux-permission-feedback-send" disabled={writing.sending}>
              {t("permission.feedbackSend")}
            </button>
          </div>
        </form>
      )}
    </PermissionCardFrame>
  );
}
