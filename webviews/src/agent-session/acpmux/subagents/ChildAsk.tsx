import { memo } from "react";
import { OpenTab } from "../conversation/icons";
import { useT } from "../i18n";
import { PermissionAsk } from "../rows/PermissionAsk";
import type { ChildAsk as ChildAskModel } from "./childAsks";
import "../conversation/cardFit.css";
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
  const open = t("subagents.open", { name: child.name });
  return (
    <section className="acpmux-pending-ask" aria-label={from} data-child-ask={child.ask.sessionId}>
      {/* The line's own width decides its layout (cardFit.css): in a narrow pane Open moves under the
          sub-session's name, and in a narrower one it is its icon. The head, not the section, is the
          size container, so the ask card under it keeps the container it measures. */}
      <div className="acpmux-pending-ask__head cv-fit cv-fit-row" data-dock-clear="">
        <span
          className="acpmux-pending-ask__label cv-fit-text"
          // tooltip-allow: a long sub-session name is cut to the line; its whole text is the tooltip
          title={from}
        >
          {from}
        </span>
        <span className="acpmux-pending-ask__actions cv-fit-actions">
          <button
            type="button"
            className="acpmux-pending-ask__dismiss"
            title={open}
            aria-label={open}
            onClick={() => onOpen(child.ask.sessionId)}
          >
            <OpenTab size={14} />
            <span className="cv-fit-label">{open}</span>
          </button>
        </span>
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
