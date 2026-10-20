import React, { useEffect, useMemo, useRef } from "react";
import { useT, type Translate } from "./i18n";
import { bareKey } from "./keyTarget";
import type { AcpmuxPermission } from "./model";
import { permissionKeys, permissionOption } from "./permissionKeys";
import { SHORTCUT_ACTIONS, useShortcut } from "./shortcuts";

type PermissionOption = AcpmuxPermission["options"][number];
type KnownPermissionKind = "allow_once" | "allow_always" | "allow_chat" | "deny";

/** Maps the ACP names we know to the pane's one permission vocabulary. An ACP kind decides by
 * itself: only a `reject_*` kind denies, and a custom kind keeps the agent's name and no shortcut.
 * Options without a kind (older fixtures and agents) fall back to their id and name. Unknown
 * options retain their agent-provided name and id, since those may be a question rather than a
 * tool decision. */
export function permissionOptionKind(option: PermissionOption): KnownPermissionKind | undefined {
  const kind = option.kind?.toLowerCase();
  if (kind === "allow_once") return "allow_once";
  if (kind === "allow_always") return "allow_always";
  if (kind?.startsWith("reject")) return "deny";
  if (kind && !kind.startsWith("allow")) return undefined;
  const value = `${kind ?? ""} ${option.id} ${option.name}`.toLowerCase();
  if (!kind && /deny|reject/.test(value)) return "deny";
  if (/allow[_ -]?(always|forever|permanent)|always/.test(value)) return "allow_always";
  if (/allow[_ -]?(chat|session)/.test(value)) return "allow_chat";
  if (/allow[_ -]?(once|one)|single|approve/.test(value)) return "allow_once";
  return undefined;
}

/** Claude Code's own words for its three permission answers. Codex keeps codex-acp's names: they
 * already match the Codex TUI, and Codex can offer several options of one kind (decline and
 * cancel, a session grant and a command-prefix rule) that one shared label would blur. A label is
 * replaced only when the ask has exactly one option of that kind. */
export function permissionOptionLabel(
  option: PermissionOption,
  t: Translate,
  harness?: string,
  options: readonly PermissionOption[] = [option],
): string {
  const claude = harness === "claude" || harness?.startsWith("claude-");
  const kind = permissionOptionKind(option);
  const sole = kind !== undefined && options.filter((other) => permissionOptionKind(other) === kind).length === 1;
  if (kind === "allow_once") {
    if (claude && sole) return t("permission.claude.yes");
    if (/^allow once$/i.test(option.name.trim())) return t("permission.allowOnce");
    return option.name;
  }
  if (kind === "allow_always" || kind === "allow_chat") {
    if (claude && sole) return t("permission.claude.dontAskAgain");
    return option.name;
  }
  if (kind === "deny") {
    if (claude && sole) return t("permission.claude.tellDifferently");
    return option.name;
  }
  return option.name;
}

function permissionCommand(permission: AcpmuxPermission): string {
  const title = permission.title?.trim() ?? "";
  return permission.command?.trim() || title.replace(/^(run|execute)\s+/i, "");
}

function permissionAction(permission: AcpmuxPermission, t: Translate): string {
  const title = permission.title?.trim() ?? "";
  return title || t("permission.required");
}

function permissionOptionDescription(
  permission: AcpmuxPermission,
  option: PermissionOption,
  kind: KnownPermissionKind | undefined,
): string | undefined {
  if (kind !== "allow_always" && kind !== "allow_chat") return option.description;
  return option.rule || permission.rule || option.description;
}

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

/// A permission ask with its options as buttons. Its configured native shortcut answers known
/// actions; the legacy bare-key path remains available for custom ACP options.
export function PermissionCard({
  permission,
  onAnswer,
  harness,
  focusComposer,
  waiting = 0,
}: {
  permission: AcpmuxPermission;
  onAnswer(optionId: string): void;
  harness?: string;
  focusComposer?: () => void;
  /// More asks waiting behind this one, answered after it.
  waiting?: number;
}) {
  const t = useT();
  const keys = useMemo(
    () => (permission.pending ? permissionKeys(permission.options) : new Map<string, string>()),
    [permission.pending, permission.options],
  );
  const group = useRef<HTMLFieldSetElement>(null);
  // The ask whose answer a key already sent: held keys repeat, and a second key can land before
  // the snapshot clears the ask, so the keyboard answers each ask once.
  const answered = useRef<string | undefined>(undefined);
  const allowOnceShortcut = useShortcut(SHORTCUT_ACTIONS.permissionAllowOnce);
  const allowChatShortcut = useShortcut(SHORTCUT_ACTIONS.permissionAllowChat);
  const denyShortcut = useShortcut(SHORTCUT_ACTIONS.permissionDeny);
  const shortcutLabels = useMemo(
    () =>
      ({
        allow_once: allowOnceShortcut,
        allow_always: allowChatShortcut,
        allow_chat: allowChatShortcut,
        deny: denyShortcut,
      }) satisfies Record<KnownPermissionKind, string | undefined>,
    [allowOnceShortcut, allowChatShortcut, denyShortcut],
  );
  // The keys reach the group from its focused buttons, so it listens natively: it is a group,
  // not a control of its own.
  useEffect(() => {
    const element = group.current;
    if (!element || !permission.pending) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.repeat || answered.current === permission.permissionId) return;
      const key = bareKey(event);
      const option = key ? permissionOption(permission.options, keys, key) : undefined;
      if (!option) return;
      event.preventDefault();
      answered.current = permission.permissionId;
      onAnswer(option.id);
      if (permissionOptionKind(option) === "deny") focusComposer?.();
    };
    element.addEventListener("keydown", onKey);
    return () => element.removeEventListener("keydown", onKey);
  }, [permission.pending, permission.permissionId, permission.options, keys, onAnswer, focusComposer]);
  useEffect(() => {
    if (!permission.pending) return;
    const actions = new Map<string, string>();
    permission.options.forEach((option) => {
      const kind = permissionOptionKind(option);
      const shortcut = kind && shortcutLabels[kind];
      if (kind && shortcut) actions.set(kind, option.id);
    });
    const handlers = (Object.keys(shortcutLabels) as KnownPermissionKind[]).map((kind) => {
      const event = `cmux-acpmux-${kind === "allow_once" ? "permissionAllowOnce" : kind === "deny" ? "permissionDeny" : "permissionAllowChat"}`;
      const handler = () => {
        const optionId = actions.get(kind);
        if (optionId && answered.current !== permission.permissionId) {
          answered.current = permission.permissionId;
          onAnswer(optionId);
          if (kind === "deny") focusComposer?.();
        }
      };
      window.addEventListener(event, handler);
      return [event, handler] as const;
    });
    return () => handlers.forEach(([event, handler]) => window.removeEventListener(event, handler));
  }, [
    permission.pending,
    permission.permissionId,
    permission.options,
    onAnswer,
    allowOnceShortcut,
    allowChatShortcut,
    denyShortcut,
    shortcutLabels,
    focusComposer,
  ]);

  return (
    <PermissionCardFrame ref={group} className="acpmux-permission-ask" ariaLabel={permissionAction(permission, t)}>
      <div className="acpmux-permission-request" data-harness={harness || undefined}>
        <div className="acpmux-permission-request-label">{permissionAction(permission, t)}</div>
        {permission.description && <p className="acpmux-permission-request-description">{permission.description}</p>}
        {waiting > 0 && <p className="acpmux-permission-waiting">{t("permission.moreWaiting", { n: waiting })}</p>}
        {permissionCommand(permission) && (
          <details className="acpmux-permission-command">
            <summary>
              <code>{permissionCommand(permission)}</code>
            </summary>
            <pre>
              <code>{permissionCommand(permission)}</code>
            </pre>
          </details>
        )}
      </div>
      <div className="acpmux-permission-buttons">
        {permission.options.map((option) => {
          const kind = permissionOptionKind(option);
          const shortcut = kind ? shortcutLabels[kind] : undefined;
          const deny = kind === "deny";
          return (
            <PermissionActionButton
              key={option.id}
              label={permissionOptionLabel(option, t, harness, permission.options)}
              description={permissionOptionDescription(permission, option, kind)}
              shortcut={shortcut}
              className={
                deny ? "acpmux-permission-deny" : kind === "allow_once" ? "acpmux-permission-primary" : undefined
              }
              onClick={() => {
                onAnswer(option.id);
                if (deny) focusComposer?.();
              }}
            />
          );
        })}
      </div>
    </PermissionCardFrame>
  );
}
