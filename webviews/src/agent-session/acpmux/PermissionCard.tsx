import React, { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { toolIcon } from "./conversation/ToolRow";
import { useT } from "./i18n";
import type { AcpmuxPermission } from "./model";
import { ProposedEdits } from "./permissions/ProposedEdits";
import {
  alwaysAllowScope,
  commandPreview,
  optionButtonLabel,
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

/// How many asks' answers a card remembers: far more than a card shows before the snapshot moves on.
const KEPT_ANSWERS = 32;

/** A button's shortcut as a light hint after its label: the modifiers fainter than the key, so the
 * eye finds 1, 2, 3 as in Claude Code's and Codex's numbered prompts. Decoration only: the button
 * carries the key in `aria-keyshortcuts`. */
function KeyHint({ shortcut }: { shortcut: string }) {
  const key = Array.from(shortcut).at(-1) ?? "";
  const modifiers = shortcut.slice(0, shortcut.length - key.length);
  return (
    <kbd className="acpmux-permission-action-shortcut" aria-hidden="true">
      {modifiers && <span className="acpmux-permission-action-modifiers">{modifiers}</span>}
      {key}
    </kbd>
  );
}

/** Shared action button so grouped and legacy cards present the same localized label and key hint.
 * Only the short label and the key: what an answer covers is the card's one scope line, never the
 * button's (Leo 2026-10-25: "the allow button ... it shouldn't be encompassing so much"). */
export function PermissionActionButton({
  label,
  shortcut,
  ...props
}: React.ButtonHTMLAttributes<HTMLButtonElement> & { label: string; shortcut?: string }) {
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
      {shortcut && <KeyHint shortcut={shortcut} />}
    </button>
  );
}

/// A permission ask as Claude Code desktop draws it: a glass card with the tool's glyph and what the
/// call does as its title, the command clamped to its first line ("Show full command" opens all of
/// it), and Allow once, Always allow and Deny, each shown only when the agent offered that kind
/// (permissions/prompt.ts), with any other option the agent offered after them: short buttons sized
/// to their labels, grouped at the card's leading edge. What they cover (the folder or app, the Always allow rule) is one muted
/// line under them, cut with an ellipsis and whole on hover. Deny opens a field for what the agent should do instead, sent with the
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
  /// Sends the answer. A promise that rejects means acpmux refused it (already answered elsewhere,
  /// withdrawn, a policy change): the card says so and its keys answer again.
  onAnswer(optionId: string): unknown;
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
  /// The one scope line: the target the ask covers, then the Always allow rule.
  const scopeLine = [scopeText, alwaysScope].filter(Boolean).join(" · ") || undefined;
  const targetId = React.useId();
  const ruleId = React.useId();
  const otherId = React.useId();
  const allowAlwaysLabel =
    allowAlways &&
    (permissionOptionKind(allowAlways) === "allow_chat" ? t("permission.allowChat") : t("permission.alwaysAllow"));
  const otherLabels = useMemo(() => {
    const taken = new Set<string>([t("permission.allowOnce"), t("permission.deny")]);
    if (allowAlwaysLabel) taken.add(allowAlwaysLabel);
    return others.map((option) => {
      const label = optionButtonLabel(option, t, taken);
      taken.add(label);
      return label;
    });
  }, [others, t, allowAlwaysLabel]);
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
  // Each ask's answer, out or taken, by the attempt that sent it: held keys repeat, a key and a
  // click can both land before the snapshot clears the ask, and the card can show an ask again
  // (another before it, then it) while its answer is still out, so each ask is answered once. A
  // refusal from acpmux (the promise `onAnswer` returns rejects) frees it again: that answer was
  // never heard. A taken answer is kept: the card can show that ask again before the snapshot
  // drops it. Only the newest taken answers are kept, so a long chat's card stays small; an answer
  // still out is kept until it settles, so its reply always finds it.
  const answers = useRef(new Map<string, { attempt: number; out: boolean }>());
  const attempts = useRef(0);
  /// The ask shown now, read when an answer settles: only its own outcome changes what the card shows.
  const shown = useRef(permission.permissionId);
  shown.current = permission.permissionId;
  /// The ask whose last answer acpmux refused: the card says so until the next answer.
  const [refused, setRefused] = useState<string>();
  type Sent = { permissionId: string; attempt: number };
  /// Starts one answer for the ask shown now; undefined while one is out or taken for it.
  const begin = (): Sent | undefined => {
    const permissionId = permission.permissionId;
    if (answers.current.has(permissionId)) return undefined;
    const attempt = ++attempts.current;
    answers.current.set(permissionId, { attempt, out: true });
    setRefused(undefined);
    return { permissionId, attempt };
  };
  /// Whether `sent` is still its ask's answer: no newer attempt for that ask has replaced it.
  const owns = (sent: Sent) => answers.current.get(sent.permissionId)?.attempt === sent.attempt;
  /// acpmux took the answer: it stays taken, among the KEPT_ANSWERS last taken; the ask shown is
  /// never forgotten.
  const taken = (sent: Sent) => {
    if (!owns(sent)) return;
    // Moved to the end: the map's order is the order answers were taken in.
    answers.current.delete(sent.permissionId);
    answers.current.set(sent.permissionId, { attempt: sent.attempt, out: false });
    let settled = 0;
    for (const answer of answers.current.values()) if (!answer.out) settled += 1;
    for (const [id, answer] of answers.current) {
      if (settled <= KEPT_ANSWERS) break;
      if (answer.out || id === shown.current) continue;
      answers.current.delete(id);
      settled -= 1;
    }
  };
  /// The ask's answer was refused: its keys and buttons answer it again, and the card says so.
  const refuse = (sent: Sent) => {
    if (!owns(sent)) return;
    answers.current.delete(sent.permissionId);
    if (shown.current === sent.permissionId) setRefused(sent.permissionId);
  };
  // After an answer the keyboard goes back to the composer, so a stray key never answers the next
  // ask in line.
  const answer = (option: PermissionOption) => {
    const sent = begin();
    if (!sent) return;
    let reply: unknown;
    try {
      reply = onAnswer(option.id);
    } catch (error) {
      reply = Promise.reject(error);
    }
    focusComposer?.();
    // A refusal is never silent, and never leaves the ask unanswerable while it still waits.
    Promise.resolve(reply).then(
      () => taken(sent),
      () => refuse(sent),
    );
  };
  const answerByKey = answer;
  /// Deny: the field for what to do instead when the pane can send it, else the deny itself.
  const deny = (byKey = false) => {
    // An answer already out or taken for the ask (a deny with feedback sending) is not given again.
    if (!denyOption || answers.current.has(permission.permissionId)) return;
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
      if (answers.current.has(permission.permissionId)) return false;
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
    if (!denyOption || !onDenyWithFeedback || writing?.sending) return;
    const sent = begin();
    if (!sent) return;
    const { permissionId } = sent;
    setDraft({ permissionId, text, sending: true });
    let denied = false;
    try {
      denied = await onDenyWithFeedback(denyOption.id, text.trim());
    } catch {
      // A throw is a refusal too: nothing says acpmux took the deny.
    }
    // The ask's draft is this attempt's while it sends: nothing else can open or send it.
    const mine = owns(sent);
    const onCard = shown.current === permissionId;
    if (denied) {
      taken(sent);
      if (mine) setDraft((draft) => (draft?.permissionId === permissionId ? undefined : draft));
      // The keyboard goes back to the composer, as a plain deny's does.
      if (mine && onCard) focusComposer?.();
      return;
    }
    // Refused (answered elsewhere, or the connection dropped): the field stays with its text.
    if (!mine) return;
    refuse(sent);
    setDraft((draft) => (draft?.permissionId === permissionId ? { permissionId, text } : draft));
    if (onCard) field.current?.focus();
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
      <ProposedEdits permissionId={permission.permissionId} diffs={permission.diffs} />
      {!writing && (
        <div className="acpmux-permission-buttons">
          {allowOnce && (
            <PermissionActionButton
              label={t("permission.allowOnce")}
              aria-describedby={scopeText ? targetId : undefined}
              shortcut={shortcuts ? allowOnceShortcut : undefined}
              className="acpmux-permission-primary"
              onClick={() => answer(allowOnce)}
            />
          )}
          {allowAlways && allowAlwaysLabel && (
            <PermissionActionButton
              label={allowAlwaysLabel}
              shortcut={shortcuts ? allowChatShortcut : undefined}
              title={alwaysScope}
              aria-describedby={[scopeText && targetId, alwaysScope && ruleId].filter(Boolean).join(" ") || undefined}
              onClick={() => answer(allowAlways)}
            />
          )}
          {denyOption && (
            <PermissionActionButton
              label={t("permission.deny")}
              shortcut={shortcuts ? denyShortcut : undefined}
              aria-describedby={scopeText ? targetId : undefined}
              className="acpmux-permission-deny"
              data-feedback-opener=""
              onClick={() => deny()}
            />
          )}
          {others.map((option, index) => {
            const label = otherLabels[index]!;
            const full = [option.name.trim(), option.description?.trim()].filter(Boolean).join(" · ");
            const more = full && full !== label ? full : undefined;
            const fullId = `${otherId}-${index}`;
            return (
              <React.Fragment key={option.id}>
                <PermissionActionButton
                  label={label}
                  title={more}
                  aria-describedby={more ? fullId : undefined}
                  className="acpmux-permission-other"
                  onClick={() => answer(option)}
                />
                {more && (
                  <span id={fullId} className="acpmux-permission-sr-only">
                    {more}
                  </span>
                )}
              </React.Fragment>
            );
          })}
        </div>
      )}
      {!writing && refused === permission.permissionId && (
        <p className="acpmux-permission-refused" role="alert">
          {t("permission.error.refused")}
        </p>
      )}
      {!writing && scopeLine && (
        <p className="acpmux-permission-scope" data-scope-kind={permission.scope?.kind} title={scopeLine}>
          {scopeText && <span id={targetId}>{scopeText}</span>}
          {scopeText && alwaysScope && " · "}
          {alwaysScope && <span id={ruleId}>{alwaysScope}</span>}
        </p>
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
