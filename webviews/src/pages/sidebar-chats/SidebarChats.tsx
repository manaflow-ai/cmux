// One chat history block of the sidebar (model.ts): a quiet header (Pinned, or Earlier, which folds
// with its chevron), one compact row per chat (its harness mark, title and a faint age on the right)
// and, for Earlier, a Show More or Loading row. Every size and column comes from the host's metrics,
// so the rows sit on the sidebar's grid as the workspace rows beside them do. Snapshots arrive as
// props; the component holds no state of its own (hover is the CSS's).
import type { CSSProperties, MouseEvent } from "react";
import { AgentMark } from "../../agent-session/shared/AgentMark";
import { Icon } from "../../agent-session/acpmux/icons/Icon";
import {
  blockHeight,
  isFoldable,
  rowLabel,
  type SidebarChatRow,
  type SidebarChatsBlock,
  type SidebarChatsStrings,
} from "./model";

export interface SidebarChatsProps {
  block: SidebarChatsBlock;
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

function Mark({ row, block }: { row: SidebarChatRow; block: SidebarChatsBlock }) {
  const side = block.metrics.glyph;
  // A harness no mark knows: the generic person mark in its stable colour (the host picks it).
  if (row.markColor)
    return (
      <span className="sc-mark" style={{ color: row.markColor }}>
        <Icon name="account" size={side} row />
      </span>
    );
  return (
    <span className="sc-mark">
      <AgentMark agent={row.harness ?? undefined} size={side} tint fallback={<Icon name="account" size={side} row />} />
    </span>
  );
}

export function SidebarChats({ block, strings, onOpen, onFold, onMore, onMenu }: SidebarChatsProps) {
  const foldable = isFoldable(block);
  const title = block.part === "pinned" ? strings.pinned : strings.earlier;
  const quiet = block.part === "earlier";
  const menu = (chat: string) => (event: MouseEvent) => {
    event.preventDefault();
    onMenu(chat, { x: event.clientX, y: event.clientY });
  };
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
      {!block.folded &&
        block.rows.map((row) => (
          <button
            key={row.id}
            type="button"
            className="sc-row"
            data-chat={row.id}
            aria-label={rowLabel(row)}
            onClick={() => onOpen(row.id)}
            onContextMenu={menu(row.id)}
          >
            {row.harness ? <Mark row={row} block={block} /> : null}
            <span className={row.harness ? "sc-title" : "sc-title sc-title-plain"}>{row.title}</span>
            {row.meta ? <span className="sc-meta">{row.meta}</span> : null}
          </button>
        ))}
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
