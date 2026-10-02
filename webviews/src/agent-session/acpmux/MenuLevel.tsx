import React from "react";
import { MenuRow } from "./MenuRow";
import type { MenuNode, MenuTree } from "./useMenuTree";

/// A DOM id for a row, from the menu's id, its level and its key.
export const rowId = (prefix: string, level: number, key: string) =>
  `${prefix}-${level}-${key.replace(/[^\w-]/g, (char) => `_${char.charCodeAt(0).toString(16)}`)}`;

/// One level of a layered model menu, with the open row's submenu (or panel) drawn right after
/// that row: CSS sets it beside the row (cascade) or above it (the drill).
export function MenuLevel({
  nodes,
  level,
  tree,
  idPrefix,
  subAbove = false,
}: {
  nodes: MenuNode[];
  level: number;
  tree: MenuTree;
  idPrefix: string;
  /// Draw an open row's submenu before it in the flow (the drill), not after (cascade, beside).
  subAbove?: boolean;
}) {
  const active = tree.activeKey(level);
  const sub = (node: MenuNode, open: boolean) =>
    open && (
      <div
        className={`acpmux-mp-sub${node.panel ? " acpmux-mp-panel" : ""}`}
        data-mp-sub={level}
        onPointerEnter={tree.cancelHover}
      >
        {node.panel ?? (
          <MenuLevel
            nodes={node.children ?? []}
            level={level + 1}
            tree={tree}
            idPrefix={idPrefix}
            subAbove={subAbove}
          />
        )}
      </div>
    );
  let section: string | undefined;
  return (
    // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
    <div className="acpmux-mp-level" role="group" data-level={level}>
      {nodes.map((node) => {
        const header = node.section && node.section !== section ? node.section : undefined;
        section = node.section;
        const open = tree.path[level] === node.key && Boolean(node.children?.length || node.panel);
        return (
          <React.Fragment key={node.key}>
            {header && <div className="acpmux-menu-header">{header}</div>}
            <div className="acpmux-mp-entry">
              {subAbove && sub(node, open)}
              <MenuRow
                node={node}
                id={rowId(idPrefix, level, node.key)}
                active={node.key === active}
                open={open}
                onHover={() => tree.hover(level, node)}
                onPick={() => tree.click(node)}
              />
              {!subAbove && sub(node, open)}
            </div>
          </React.Fragment>
        );
      })}
    </div>
  );
}
