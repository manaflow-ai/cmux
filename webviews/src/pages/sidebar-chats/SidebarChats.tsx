// One chat history block of the sidebar (model.ts): a quiet header (Pinned, or Earlier, which folds
// with its chevron), one compact row per chat (its harness mark, title and a faint age on the right)
// and, for Earlier, a Show More or Loading row. Every size and column comes from the host's metrics,
// so the rows sit on the sidebar's grid as the workspace rows beside them do. Snapshots arrive as
// props; the component holds no state of its own (hover is the CSS's). Each row is memoized on its own
// primitive fields, so a new block (a new revision, or the host's age tick) draws again only the rows
// whose title, mark or age changed: the host dates each row's age itself (`meta`, "12m"), so no clock
// reaches a row whose label stayed the same. The handlers must keep their identity (mount.tsx does).
// Once the host sends the slice of the page the sidebar shows, only the rows near it mount, between two
// spacers that keep every other row's place, so the block's height (and `ready`'s) stays the same.
import { memo, type CSSProperties, type MouseEvent } from "react";
import { AgentMark } from "../../agent-session/shared/AgentMark";
import { Icon } from "../../agent-session/acpmux/icons/Icon";
import {
  blockHeight,
  isFoldable,
  rowLabel,
  sliceRange,
  type SidebarChatsBlock,
  type SidebarChatsSlice,
  type SidebarChatsStrings,
} from "./model";

export interface SidebarChatsProps {
  block: SidebarChatsBlock;
  /** The part of the page the sidebar shows; null before the host's first: every row mounts. */
  slice?: SidebarChatsSlice | null;
  strings: SidebarChatsStrings;
  onOpen(chat: string): void;
  onFold(): void;
  onMore(): void;
  onMenu(chat: string, point: { x: number; y: number }): void;
}

/** The metrics as the stylesheet's custom properties. */
function metricVars(block: SidebarChatsBlock): CSSProperties {
  const m = block.metrics;
  const px = (value: number) => `${value}px`;
  return {
    "--sc-header": px(m.header),
    "--sc-row": px(m.row),
    "--sc-spacing": px(m.spacing),
    "--sc-radius": px(m.radius),
    "--sc-icon-x": px(m.iconX),
    "--sc-icon-box": px(m.iconBox),
    "--sc-text-x": px(m.textX),
    "--sc-plain-text-x": px(m.plainTextX),
    "--sc-header-x": px(m.headerX),
    "--sc-edge": px(m.edge),
    "--sc-header-end": px(m.headerEnd),
    "--sc-chevron-end": px(m.chevronEnd),
    "--sc-chevron": px(m.chevron),
    "--sc-title-size": px(m.titleSize),
    "--sc-meta-size": px(m.metaSize),
    "--sc-header-size": px(m.headerSize),
    height: px(blockHeight(block)),
  } as CSSProperties;
}

function Mark({ harness, markColor, side }: { harness: string | null; markColor: string | null; side: number }) {
  // A harness no mark knows: the generic person mark in its stable colour (the host picks it).
  if (markColor)
    return (
      <span className="sc-mark" style={{ color: markColor }}>
        <Icon name="account" size={side} row />
      </span>
    );
  return (
    <span className="sc-mark">
      <AgentMark agent={harness ?? undefined} size={side} tint fallback={<Icon name="account" size={side} row />} />
    </span>
  );
}

interface ChatRowProps {
  id: string;
  title: string;
  meta: string | null;
  harness: string | null;
  markColor: string | null;
  glyph: number;
  onOpen(chat: string): void;
  onMenu(chat: string, point: { x: number; y: number }): void;
}

/** One chat row, drawn again only when one of its own fields changes. */
const ChatRow = memo(function ChatRow({ id, title, meta, harness, markColor, glyph, onOpen, onMenu }: ChatRowProps) {
  return (
    <button
      type="button"
      className="sc-row"
      data-chat={id}
      aria-label={rowLabel({ id, title, meta, harness })}
      onClick={() => onOpen(id)}
      onContextMenu={(event: MouseEvent) => {
        event.preventDefault();
        onMenu(id, { x: event.clientX, y: event.clientY });
      }}
    >
      {harness ? <Mark harness={harness} markColor={markColor} side={glyph} /> : null}
      <span className={harness ? "sc-title" : "sc-title sc-title-plain"}>{title}</span>
      {meta ? <span className="sc-meta">{meta}</span> : null}
    </button>
  );
});

/** Holds the place of `count` unmounted rows (each a row and its spacing). */
function Spacer({ count, stride }: { count: number; stride: number }) {
  if (count <= 0) return null;
  return <div className="sc-spacer" aria-hidden="true" style={{ height: `${count * stride}px` }} />;
}

export function SidebarChats({ block, slice, strings, onOpen, onFold, onMore, onMenu }: SidebarChatsProps) {
  const foldable = isFoldable(block);
  const title = block.part === "pinned" ? strings.pinned : strings.earlier;
  const quiet = block.part === "earlier";
  const { start, end } = slice ? sliceRange(block, slice) : { start: 0, end: block.rows.length };
  const stride = block.metrics.row + block.metrics.spacing;
  return (
    <section
      className="sc-block"
      data-part={block.part}
      data-quiet={quiet || undefined}
      aria-label={title}
      style={metricVars(block)}
      onContextMenu={(event) => event.preventDefault()}
    >
      {foldable ? (
        <button type="button" className="sc-header sc-header-foldable" aria-expanded={!block.folded} onClick={onFold}>
          <span className="sc-header-name">{title}</span>
          <span className="sc-chevron" aria-hidden="true">
            <Icon
              name={block.folded ? "disclosure.collapsed" : "disclosure.expanded"}
              size={block.metrics.chevron}
              row
            />
          </span>
        </button>
      ) : (
        <h2 className="sc-header">
          <span className="sc-header-name">{title}</span>
        </h2>
      )}
      {!block.folded && <Spacer count={start} stride={stride} />}
      {!block.folded &&
        block.rows
          .slice(start, end)
          .map((row) => (
            <ChatRow
              key={row.id}
              id={row.id}
              title={row.title}
              meta={row.meta ?? null}
              harness={row.harness ?? null}
              markColor={row.markColor ?? null}
              glyph={block.metrics.glyph}
              onOpen={onOpen}
              onMenu={onMenu}
            />
          ))}
      {!block.folded && <Spacer count={block.rows.length - end} stride={stride} />}
      {!block.folded && block.tail ? (
        <button
          type="button"
          className="sc-row sc-tail"
          data-tail={block.tail}
          aria-disabled={block.tail === "loading" || undefined}
          onClick={block.tail === "more" ? onMore : undefined}
        >
          <span className="sc-title sc-title-plain">{block.tail === "more" ? strings.showMore : strings.loading}</span>
        </button>
      ) : null}
    </section>
  );
}
