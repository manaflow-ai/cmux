// A hat line's open detail (SubagentTray.tsx): a click anywhere on a line expands it in place, under
// the line inside the hat, and a second click folds it, on the shared fold every other hat expansion
// uses (conversation/fold.ts `useFold`). A click never takes the person to the subagent, the chat or the
// terminal; that is an explicit button in the detail (Leo, 2026-11-07: "me clicking this, the entire box,
// it just feels like, okay, I would be expanding this. I don't expect myself to be going to the exact
// place, right?").
import type { ReactNode } from "react";
import { useFold } from "../conversation/fold";
import { entranceAllowed } from "../../shared/pageReveal";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";

/// The fold around a line's detail: drawn while open and while it folds away, so a detail that polls
/// (BackgroundTaskTail.tsx) runs only then.
export function TrayLineFold({ open, children }: { open: boolean; children: ReactNode }) {
  const fold = useFold(open, entranceAllowed);
  if (!fold.present) return null;
  return (
    <div ref={fold.ref} className="acpmux-running-tray__line-detail" data-line-detail inert={!open || undefined}>
      {children}
    </div>
  );
}

/// A subagent's or a started chat's detail: its whole task, what it does now, and Open chat.
export function TrayAgentDetail({
  name,
  task,
  latest,
  meta,
  onOpen,
}: {
  /// What the line names it: Open chat says whose chat it opens to a screen reader.
  name: string;
  task?: string;
  latest?: string;
  meta?: string;
  onOpen?: () => void;
}) {
  const t = useT();
  if (!task && !latest && !meta && !onOpen) return null;
  return (
    <div className="acpmux-running-tray__tail" data-agent-detail>
      {task && <p className="acpmux-running-tray__detail-task">{task}</p>}
      {latest && latest !== task && <p className="acpmux-running-tray__detail-latest">{latest}</p>}
      {(meta || onOpen) && (
        <div className="acpmux-running-tray__tail-foot">
          {meta && <span className="acpmux-running-tray__meta">{meta}</span>}
          {onOpen && (
            <button type="button" aria-label={t("subagents.open", { name })} onClick={onOpen}>
              <Icon name="agent.chat" size={12} row />
              {t("subsession.openChat")}
            </button>
          )}
        </div>
      )}
    </div>
  );
}
