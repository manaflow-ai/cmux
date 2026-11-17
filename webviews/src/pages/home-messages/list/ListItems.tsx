// One conversation in the Messages list: a row (avatar, name and tag, time, a two-line preview, the
// unread dot in the gutter) or a pinned tile (a big avatar with the name under it and its unread
// dot), as the native list (MessagesLab's sidebar) draws them. The avatar is the participant's
// picture or their initials; a group shows up to three members. A Chief's avatar is plain: no
// working or waiting mark, only the unread dot (HomeChiefAvatarPlainTests). A teammate with no DM
// yet is a row of its own (avatar and name); a swiped row slides over its actions (swipe.ts).
import type { CSSProperties, PointerEvent as ReactPointerEvent } from "react";
import { DrivenRow } from "../../../ui/DrivenList";
import { useAvatarPicture } from "../../home-channels/avatars";
import { graphemePrefix, initials } from "../../../ui/initials";
import type { HomeParticipant } from "../../home-channels/types";
import type { ListItem, TeammateItem } from "./model";
import { SWIPE_BUTTON, type SwipeAction } from "./swipe";

export function ListAvatar({ item, size }: { item: ListItem; size: number }) {
  if (item.peer || item.members.length <= 1) {
    return <PersonAvatar participant={item.peer ?? item.members[0]} name={item.title} size={size} />;
  }
  // A group: its first three members, overlapping on one disc's footprint.
  const members = item.members.slice(0, 3);
  const small = Math.round(size * 0.62);
  return (
    <span className="hm-avatar-group" style={{ width: size, height: size }} aria-hidden="true">
      {members.map((member, index) => (
        <span key={member.id} className={`hm-avatar-slot slot-${members.length}-${index}`}>
          <PersonAvatar participant={member} name={member.name} size={small} />
        </span>
      ))}
    </span>
  );
}

function PersonAvatar({ participant, name, size }: { participant?: HomeParticipant; name: string; size: number }) {
  const picture = useAvatarPicture(participant?.id);
  const agent = participant?.kind === "agent";
  const style = { width: size, height: size, "--hm-avatar-size": `${size}px` } as CSSProperties;
  return (
    <span
      className={`hm-avatar${size <= 26 ? " small" : size >= 52 ? " big" : ""}${agent ? " agent" : ""}${participant?.chief ? " chief" : ""}${picture ? " picture" : ""}`}
      style={style}
      aria-hidden="true"
    >
      {picture ? (
        <img className="hm-avatar-img" src={picture} alt="" draggable={false} />
      ) : (
        graphemePrefix(initials(participant?.name ?? name), size >= 24 ? 2 : 1)
      )}
    </span>
  );
}

/** The keys held during a click. */
export interface Modifiers {
  metaKey: boolean;
  shiftKey: boolean;
  ctrlKey: boolean;
}

export interface ItemEvents {
  /** A click (or Return on the row): its modifiers say whether it opens too. */
  onClick(id: string, event: Modifiers): void;
  onPointerDown(id: string, fromGrid: boolean, event: ReactPointerEvent): void;
  onHover(id: string): void;
}

export function ListRow({
  item,
  top,
  selected,
  compact,
  avatar,
  height,
  separator,
  events,
  dragging,
  swipeX = 0,
  settling = false,
}: {
  item: ListItem;
  top: number;
  selected: boolean;
  compact: boolean;
  avatar: number;
  height: number;
  /** The hairline under the row (none under the selected row or the one above it). */
  separator: boolean;
  events: ItemEvents;
  dragging: boolean;
  /** The row's swipe offset (right positive), and whether it is settling (open, closed). */
  swipeX?: number;
  settling?: boolean;
}) {
  return (
    <DrivenRow
      kind="option"
      id={`hm-item-${item.id}`}
      aria-selected={selected}
      aria-label={item.label}
      data-list-row={item.id}
      className={`hm-row${compact ? " compact" : ""}${selected ? " selected" : ""}${item.unread ? " unread" : ""}${item.muted ? " muted" : ""}${separator ? " separated" : ""}${dragging ? " dragging" : ""}${swipeX ? " swiped" : ""}${settling ? " settling" : ""}`}
      style={{ transform: `translate(${swipeX}px, ${top}px)`, height, "--hm-disc": `${avatar + 8}px` } as CSSProperties}
      onPick={(event) => events.onClick(item.id, event)}
      onPointerDown={(event) => events.onPointerDown(item.id, false, event)}
      onPointerEnter={() => events.onHover(item.id)}
    >
      {item.unread && <span className="hm-dot" aria-hidden="true" />}
      <span className="hm-row-avatar">
        <ListAvatar item={item} size={avatar} />
      </span>
      {compact ? (
        <span className="hm-tile-name">{item.title}</span>
      ) : (
        <>
          <span className="hm-row-head">
            <span className="hm-row-name">{item.title}</span>
            {item.badge && <span className="hm-tag">{item.badge}</span>}
            <time className="hm-row-time">{item.time}</time>
          </span>
          <span className="hm-row-preview">{item.preview}</span>
        </>
      )}
    </DrivenRow>
  );
}

/** A team member with no DM yet: their avatar and name. Choosing them starts the DM. */
export function TeammateRow({
  item,
  top,
  height,
  compact,
  avatar,
  onPick,
}: {
  item: TeammateItem;
  top: number;
  height: number;
  compact: boolean;
  avatar: number;
  onPick(item: TeammateItem): void;
}) {
  return (
    <DrivenRow
      kind="option"
      aria-selected={false}
      aria-label={item.label}
      data-teammate-row={item.person.id}
      className={`hm-row teammate${compact ? " compact" : ""}`}
      style={{ transform: `translateY(${top}px)`, height }}
      onPick={() => onPick(item)}
    >
      <span className="hm-row-avatar">
        <PersonAvatar participant={item.person} name={item.title} size={avatar} />
      </span>
      {compact ? (
        <span className="hm-tile-name">{item.title}</span>
      ) : (
        <span className="hm-row-head">
          <span className="hm-row-name">{item.title}</span>
        </span>
      )}
    </DrivenRow>
  );
}

/** The actions behind a swiped row, sharing the revealed width (each `SWIPE_BUTTON` wide once open). */
export function SwipeStrip({
  top,
  height,
  offset,
  open,
  settling,
  actions,
  labels,
  onAction,
}: {
  top: number;
  height: number;
  offset: number;
  open: boolean;
  settling: boolean;
  actions: readonly SwipeAction[];
  labels: Record<SwipeAction, string>;
  onAction(action: SwipeAction): void;
}) {
  const width = open ? actions.length * SWIPE_BUTTON : Math.abs(offset);
  const leading = offset > 0;
  return (
    <div
      className={`hm-swipe-strip${leading ? " leading" : " trailing"}${settling ? " settling" : ""}`}
      style={{ transform: `translateY(${top}px)`, height, width }}
    >
      {actions.map((action) => (
        <button
          key={action}
          type="button"
          className={`hm-swipe-action ${action}`}
          aria-label={labels[action]}
          title={labels[action]}
          onPointerDown={(event) => event.stopPropagation()}
          onClick={(event) => {
            event.stopPropagation();
            onAction(action);
          }}
        >
          <SwipeGlyph action={action} />
        </button>
      ))}
    </div>
  );
}

function SwipeGlyph({ action }: { action: SwipeAction }) {
  return (
    <svg
      width="20"
      height="20"
      viewBox="0 0 20 20"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {action === "delete" ? (
        <path d="M4 6h12M8 6V4.5h4V6M5.5 6l.8 9.5h7.4l.8-9.5M8.5 9v4M11.5 9v4" />
      ) : (
        <path d="M3.5 6h13v8.5h-13zM3.5 6 10 11l6.5-5" />
      )}
    </svg>
  );
}

export function PinnedTile({
  item,
  x,
  y,
  width,
  height,
  avatar,
  compact,
  selected,
  events,
  lifted,
}: {
  item: ListItem;
  x: number;
  y: number;
  width: number;
  height: number;
  avatar: number;
  compact: boolean;
  selected: boolean;
  events: ItemEvents;
  /** The tile follows the pointer (a drag): no transition, above the others. */
  lifted: boolean;
}) {
  return (
    <DrivenRow
      kind="option"
      id={`hm-item-${item.id}`}
      aria-selected={selected}
      aria-label={item.label}
      data-pinned-tile={item.id}
      className={`hm-tile${compact ? " compact" : ""}${selected ? " selected" : ""}${item.unread ? " unread" : ""}${item.muted ? " muted" : ""}${lifted ? " lifted" : ""}`}
      style={
        { transform: `translate(${x}px, ${y}px)`, width, height, "--hm-pin-avatar": `${avatar}px` } as CSSProperties
      }
      onPick={(event) => events.onClick(item.id, event)}
      onPointerDown={(event) => events.onPointerDown(item.id, true, event)}
      onPointerEnter={() => events.onHover(item.id)}
    >
      <span className="hm-tile-avatar">
        <ListAvatar item={item} size={avatar} />
      </span>
      <span className="hm-tile-name">
        {item.unread && <span className="hm-dot inline" aria-hidden="true" />}
        {item.title}
      </span>
    </DrivenRow>
  );
}
