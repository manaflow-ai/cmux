import { memo } from "react";
import { useT } from "../i18n";
import { PermissionAsk } from "../rows/PermissionAsk";
import type { ChildAsk as ChildAskModel } from "./childAsks";
import "../conversation/PendingAsks.css";

/// A sub-session's ask, in the chat above it (childAsks.ts): the line the pinned asks use, naming the
/// sub-session that asked, with Open to show that chat, over the same card the chat's own asks use,
/// keys included. It answers through this chat: acpmux takes the person's answer sent here for an
/// ask pending in an open sub-session below it as that sub-session's (server/requests.rs
/// `route_ask_below`), and the sub-session continues. Shown only while this chat has no ask of its
/// own: that one's card holds the keys, and this comes next.
export const ChildAsk = memo(function ChildAsk({
  child,
  waiting,
  shortcuts,
  focusComposer,
  onOpen,
}: {
  child: ChildAskModel;
  /// More asks below waiting behind this one.
  waiting: number;
  /// False while a permission group's panel takes the shortcuts (permissionKeys.ts).
  shortcuts: boolean;
  focusComposer?: () => void;
  /// Shows the sub-session's chat (Needs you's `chat.asks.open`).
  onOpen: (sessionId: string) => void;
}) {
  const t = useT();
  const from = t(child.direct ? "message.from.subsession" : "message.from.descendant", { name: child.name });
  return (
    <section className="acpmux-pending-ask" aria-label={from} data-child-ask={child.ask.sessionId}>
      <div className="acpmux-pending-ask__head">
        <span className="acpmux-pending-ask__label">{from}</span>
        <button type="button" className="acpmux-pending-ask__dismiss" onClick={() => onOpen(child.ask.sessionId)}>
          {t("subagents.open", { name: child.name })}
        </button>
      </div>
      <PermissionAsk
        key={child.ask.permission.permissionId}
        permission={child.ask.permission}
        harness={child.harness}
        shortcuts={shortcuts}
        waiting={waiting}
        focusComposer={focusComposer}
        // A sub-session's plan builds from its own chat: the build answers the shown chat's ask.
        buildsPlan={false}
      />
    </section>
  );
});
