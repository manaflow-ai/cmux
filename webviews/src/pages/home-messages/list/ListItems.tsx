// One conversation in the Messages list: a row (avatar, name and tag, time, a two-line preview, the
// unread dot in the gutter) or a pinned tile (a big avatar with the name under it and its unread
// dot), as the native list (MessagesLab's sidebar) draws them. The avatar is the participant's
// picture or their initials; a group shows up to three members; a Chief working shows a quiet mark.
import { memo, type CSSProperties, type PointerEvent as ReactPointerEvent } from "react";
import { DrivenRow } from "../../../ui/DrivenList";
import { useAvatarPicture } from "../../home-channels/avatars";
import { graphemePrefix, initials } from "../../../ui/initials";
import type { HomeParticipant } from "../../home-channels/types";
import type { ListItem } from "./model";

export function ListAvatar({ item, size }: { item: ListItem; size: number }) {
  if (item.peer || item.members.length <= 1) {
    return <PersonAvatar participant={item.peer ?? item.members[0]} name={item.title} size={size} state={item.state} />;
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

function PersonAvatar({
  participant,
  name,
  size,
  state,
}: {
  participant?: HomeParticipant;
  name: string;
  size: number;
  state?: ListItem["state"];
}) {
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
      {state && <span className={`hm-state-mark ${state}`} />}
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

const sameParticipant = (a: HomeParticipant | undefined, b: HomeParticipant | undefined) =>
  a === b || (!!a && !!b && a.id === b.id && a.name === b.name && a.kind === b.kind && a.chief === b.chief);

const sameMembers = (a: readonly HomeParticipant[], b: readonly HomeParticipant[]) =>
  a.length === b.length && a.slice(0, 3).every((member, index) => sameParticipant(member, b[index]));

type Same<T> = (a: T, b: T) => boolean;

/**
 * How a row or tile compares each `ListItem` field, in one place: a field it draws gets its test,
 * a field it does not draw is `null` and says where it shows instead. A new field fails to compile
 * here until it is given one, so the compare cannot drift from what the row draws either way (a
 * field drawn but not compared shows stale text; one compared but not drawn redraws for nothing).
 */
const LOOK: { [K in keyof ListItem]-?: Same<ListItem[K]> | null } = {
  id: Object.is,
  title: Object.is,
  label: Object.is,
  preview: Object.is,
  time: Object.is,
  badge: Object.is,
  unread: Object.is,
  muted: Object.is,
  state: Object.is,
  peer: sameParticipant,
  members: sameMembers,
  // Shown only through `label` (the count, the mention) or `badge` (Channel), compared above.
  unreadCount: null,
  mentions: null,
  channel: null,
  // Where the item sits (its order, the pinned tiles or the rows), not what it draws.
  at: null,
  pinned: null,
  // The record the fields come from; the row's handlers take the id.
  conversation: null,
};
const LOOK_FIELDS = Object.entries(LOOK).filter((entry): entry is [keyof ListItem, Same<unknown>] => entry[1] !== null);

/** Whether two items draw the same (the list model builds every item again on each change and on its
 * minute clock): every field the row or tile draws, by `LOOK`. */
export function sameLook(a: ListItem, b: ListItem): boolean {
  return a === b || LOOK_FIELDS.every(([key, same]) => same(a[key], b[key]));
}

/** Memo for a row or tile: its other props are numbers, booleans and the list's one `events`. */
function sameItemProps<P extends { item: ListItem }>(a: P, b: P): boolean {
  for (const key in a) {
    if (key === "item") continue;
    if (!Object.is(a[key], b[key])) return false;
  }
  return sameLook(a.item, b.item);
}

export const ListRow = memo(function ListRow({
  item,
  top,
  selected,
  compact,
  avatar,
  height,
  separator,
  events,
  dragging,
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
}) {
  return (
    <DrivenRow
      kind="option"
      id={`hm-item-${item.id}`}
      aria-selected={selected}
      aria-label={item.label}
      data-list-row={item.id}
      className={`hm-row${compact ? " compact" : ""}${selected ? " selected" : ""}${item.unread ? " unread" : ""}${item.muted ? " muted" : ""}${separator ? " separated" : ""}${dragging ? " dragging" : ""}`}
      style={{ transform: `translateY(${top}px)`, height }}
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
}, sameItemProps);

export const PinnedTile = memo(function PinnedTile({
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
}, sameItemProps);
