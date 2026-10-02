import React, { useEffect, useId, useMemo, useRef } from "react";
import { t } from "./i18n";
import { bareKey } from "./keyTarget";
import { Keycap } from "./Keycap";
import type { AcpmuxPermission } from "./model";
import { permissionKeys, permissionOption } from "./permissionKeys";

/// A permission ask with its options as buttons. While it waits, each button shows its key and a
/// bare key pressed inside the ask answers it (y, a, n, or a position). The ask never takes focus
/// from the prompt; the app's leader key reaches it from anywhere.
export function PermissionCard({
  permission,
  onAnswer,
}: {
  permission: AcpmuxPermission;
  onAnswer(optionId: string): void;
}) {
  const keys = useMemo(
    () => (permission.pending ? permissionKeys(permission.options) : new Map<string, string>()),
    [permission.pending, permission.options],
  );
  const title = permission.title || t("permission.required");
  const titleId = useId();
  const group = useRef<HTMLFieldSetElement>(null);
  // The ask whose answer a key already sent: held keys repeat, and a second key can land before
  // the snapshot clears the ask, so the keyboard answers each ask once.
  const answered = useRef<string | undefined>(undefined);
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
  return (
    <fieldset ref={group} className="acpmux-permission-card" aria-labelledby={titleId}>
      <strong id={titleId}>{title}</strong>
      <div className="acpmux-permission-buttons">
        {permission.options.map((option) => {
          const key = keys.get(option.id);
          return (
            <button key={option.id} type="button" aria-keyshortcuts={key} onClick={() => onAnswer(option.id)}>
              {key && <Keycap>{key}</Keycap>}
              {option.name}
            </button>
          );
        })}
      </div>
    </fieldset>
  );
}
