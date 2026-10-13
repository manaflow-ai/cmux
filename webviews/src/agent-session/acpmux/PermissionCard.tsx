import React, { useEffect, useMemo, useRef } from "react";
import { useT, type Translate } from "./i18n";
import { bareKey } from "./keyTarget";
import type { AcpmuxPermission } from "./model";
import { permissionKeys, permissionOption } from "./permissionKeys";
import { SHORTCUT_ACTIONS, useShortcut, withShortcut } from "./shortcuts";

type PermissionOption = AcpmuxPermission["options"][number];
type KnownPermissionKind = "allow_once" | "allow_chat" | "deny";

/** Maps the ACP names we know to the pane's one permission vocabulary. Unknown options retain
 * their agent-provided name and id, since those may be a question rather than a tool decision. */
export function permissionOptionKind(option: PermissionOption): KnownPermissionKind | undefined {
  const value = `${option.kind ?? ""} ${option.id} ${option.name}`.toLowerCase();
  if (/deny|reject/.test(value)) return "deny";
  if (/allow[_ -]?(chat|session)/.test(value)) return "allow_chat";
  if (/allow[_ -]?(once|one)|single|approve/.test(value)) return "allow_once";
  return undefined;
}

export function permissionOptionLabel(option: PermissionOption, t: Translate): string {
  const kind = permissionOptionKind(option);
  if (kind === "allow_once") return t("permission.allowOnce");
  if (kind === "allow_chat") return t("permission.allowChat");
  if (kind === "deny") return t("permission.deny");
  return option.name;
}

/** The single card frame used by legacy ACP asks and grouped tool permissions. */
type PermissionCardFrameProps = {
  title?: string;
  leading?: React.ReactNode;
  children: React.ReactNode;
  className?: string;
};

export const PermissionCardFrame = React.forwardRef<HTMLFieldSetElement, PermissionCardFrameProps>(
  function PermissionCardFrame({ title, leading, children, className }, ref) {
    const titleId = React.useId();
    return (
      <fieldset
        ref={ref}
        className={`acpmux-permission-card${className ? ` ${className}` : ""}`}
        aria-labelledby={title ? titleId : undefined}
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
  ...props
}: React.ButtonHTMLAttributes<HTMLButtonElement> & { label: string; shortcut?: string }) {
  return (
    <button {...props} type="button" aria-keyshortcuts={shortcut || undefined}>
      {withShortcut(label, shortcut)}
    </button>
  );
}

/// A permission ask with its options as buttons. Its configured native shortcut answers known
/// actions; the legacy bare-key path remains available for custom ACP options.
export function PermissionCard({
  permission,
  onAnswer,
}: {
  permission: AcpmuxPermission;
  onAnswer(optionId: string): void;
}) {
  const t = useT();
  const keys = useMemo(
    () => (permission.pending ? permissionKeys(permission.options) : new Map<string, string>()),
    [permission.pending, permission.options],
  );
  const title = permission.title || t("permission.required");
  const group = useRef<HTMLFieldSetElement>(null);
  // The ask whose answer a key already sent: held keys repeat, and a second key can land before
  // the snapshot clears the ask, so the keyboard answers each ask once.
  const answered = useRef<string | undefined>(undefined);
  const allowOnceShortcut = useShortcut(SHORTCUT_ACTIONS.permissionAllowOnce);
  const allowChatShortcut = useShortcut(SHORTCUT_ACTIONS.permissionAllowChat);
  const denyShortcut = useShortcut(SHORTCUT_ACTIONS.permissionDeny);
  const shortcutLabels = {
    allow_once: allowOnceShortcut,
    allow_chat: allowChatShortcut,
    deny: denyShortcut,
  } satisfies Record<KnownPermissionKind, string | undefined>;
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
    };
    element.addEventListener("keydown", onKey);
    return () => element.removeEventListener("keydown", onKey);
  }, [permission.pending, permission.permissionId, permission.options, keys, onAnswer]);
  useEffect(() => {
    if (!permission.pending) return;
    const actions = new Map<string, string>();
    permission.options.forEach((option) => {
      const kind = permissionOptionKind(option);
      const shortcut = kind && shortcutLabels[kind];
      if (kind && shortcut) actions.set(kind, option.id);
    });
    const handlers = (Object.keys(shortcutLabels) as KnownPermissionKind[]).map((kind) => {
      const event = `cmux-acpmux-${kind === "allow_once" ? "permissionAllowOnce" : kind === "allow_chat" ? "permissionAllowChat" : "permissionDeny"}`;
      const handler = () => {
        const optionId = actions.get(kind);
        if (optionId && answered.current !== permission.permissionId) {
          answered.current = permission.permissionId;
          onAnswer(optionId);
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
  ]);

  return (
    <PermissionCardFrame ref={group} title={title}>
      <div className="acpmux-permission-buttons">
        {permission.options.map((option) => {
          const kind = permissionOptionKind(option);
          const shortcut = kind ? shortcutLabels[kind] : undefined;
          return (
            <PermissionActionButton
              key={option.id}
              label={permissionOptionLabel(option, t)}
              shortcut={shortcut}
              onClick={() => onAnswer(option.id)}
            />
          );
        })}
      </div>
    </PermissionCardFrame>
  );
}
