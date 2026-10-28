// l10n-allow-file: gallery prototype (sample labels), not shipped UI.
// The six ways the sidebar can show a session family: columns (one column per level, Miller style),
// tree (indented, collapsible), grouped (by status, task kind or harness), lanes (a timeline of who
// ran when), stack (one level at a time with a breadcrumb, the iPhone's natural form) and digest
// (only what needs you or is moving; the rest folds into counts).
import { useState, type ReactNode } from "react";
import {
  ago,
  childrenOf,
  descendants,
  HARNESS_LABEL,
  KIND_LABEL,
  pathTo,
  STATE_LABEL,
  stateCounts,
  type AgentKind,
  type AgentNode,
  type AgentState,
  type Harness,
} from "./hierarchy";
import { Chevron, HarnessMark, Shimmer, StatusMark, type Platform } from "./parts";

export type ViewProps = {
  nodes: readonly AgentNode[];
  platform: Platform;
  /** The selected chain, root first. */
  path: readonly AgentNode[];
  onSelect: (node: AgentNode) => void;
  /** The header's limit line for the focused session (rendered by the caller). */
  header?: ReactNode;
};

/** One agent: status, name (the running one shimmers its last event), quiet count and age. */
export function AgentRow({
  node,
  platform,
  selected,
  onSelect,
  indent = 0,
  lead,
  second,
  trailing,
}: {
  node: AgentNode;
  platform: Platform;
  selected?: boolean;
  onSelect?: (node: AgentNode) => void;
  indent?: number;
  lead?: ReactNode;
  second?: ReactNode;
  trailing?: ReactNode;
}) {
  return (
    <button
      type="button"
      className="sa-row"
      data-platform={platform}
      data-state={node.state}
      data-selected={selected || undefined}
      style={indent ? { paddingInlineStart: `calc(var(--sa-row-pad) + ${indent}px)` } : undefined}
      onClick={() => onSelect?.(node)}
    >
      {lead}
      <StatusMark state={node.state} />
      <span className="sa-row-text">
        <span className="sa-row-title">{node.name}</span>
        {second !== undefined ? (
          second && <span className="sa-row-second">{second}</span>
        ) : (
          <span className="sa-row-second">
            {node.state === "running" ? <Shimmer>{node.lastEvent}</Shimmer> : node.lastEvent}
          </span>
        )}
      </span>
      {trailing ?? (
        <span className="sa-row-meta">
          {node.childCount > 0 && <span className="sa-count">{node.childCount}</span>}
          <span>{ago(node.lastEventAgo)}</span>
        </span>
      )}
    </button>
  );
}

// ---------------------------------------------------------------------------------------------
// Columns

/** A column's width in px (Mac) and the strip a collapsed level shrinks to. */
export const COLUMN_WIDTH = 232;
export const STRIP_WIDTH = 30;

export function columnsWidth(levels: number, visible: number): number {
  const shown = Math.min(levels, visible);
  return shown * COLUMN_WIDTH + (levels - shown) * STRIP_WIDTH;
}

/**
 * One column per level: sessions, then the children of each selected agent. The newest `visible`
 * levels show in full; the earlier ones fold into thin strips (status mark and depth) that open on
 * click. On iPhone the current level fills the screen and the parent peeks at the leading edge.
 */
export function ColumnsView({ nodes, platform, path, onSelect, header, visible }: ViewProps & { visible: number }) {
  const roots = childrenOf(nodes, null);
  const levels: { parent: AgentNode | null; items: AgentNode[] }[] = [{ parent: null, items: roots }];
  for (const node of path) {
    const items = childrenOf(nodes, node.id);
    if (items.length) levels.push({ parent: node, items });
  }
  const [unfolded, setUnfolded] = useState<number | null>(null);
  const shownFrom = platform === "iphone" ? levels.length - 1 : Math.max(0, levels.length - visible);
  return (
    <div className="sa-columns" data-platform={platform}>
      {levels.map((level, index) => {
        const selectedId = path[index]?.id;
        const folded = index < shownFrom && unfolded !== index;
        if (platform === "iphone" && index < shownFrom - 1) return null;
        if (folded)
          return (
            <button
              key={level.parent?.id ?? "roots"}
              type="button"
              className="sa-strip"
              data-platform={platform}
              aria-label={`Show ${level.parent?.name ?? "Sessions"}`}
              onClick={() => setUnfolded(index)}
            >
              <span className="sa-strip-depth">{index === 0 ? "S" : index}</span>
              {path[index] && <StatusMark state={path[index]!.state} />}
              {platform === "iphone" && path[index] && <span className="sa-strip-name">{path[index]!.name}</span>}
            </button>
          );
        // Width counts open children (PROTOCOL.md): a finished child holds its slot until it is closed.
        const used = level.items.length;
        return (
          <section
            key={level.parent?.id ?? "roots"}
            className="sa-column"
            data-platform={platform}
            aria-label={level.parent?.name ?? "Sessions"}
          >
            <header className="sa-column-header">
              <span className="sa-column-title">{level.parent ? level.parent.name : "Sessions"}</span>
              <span className="sa-muted">
                {level.parent ? `${used}/${level.parent.limits.width}` : roots.length}
                {index > 0 && ` · L${index}`}
              </span>
            </header>
            {index === levels.length - 1 && header}
            <div className="sa-column-list">
              {level.items.map((item) => (
                <AgentRow
                  key={item.id}
                  node={item}
                  platform={platform}
                  selected={item.id === selectedId}
                  onSelect={(node) => {
                    setUnfolded(null);
                    onSelect(node);
                  }}
                  trailing={
                    <span className="sa-row-meta">
                      {item.childCount > 0 && <span className="sa-count">{item.childCount}</span>}
                      {item.childCount > 0 && <Chevron open={item.id === selectedId} />}
                    </span>
                  }
                />
              ))}
            </div>
          </section>
        );
      })}
    </div>
  );
}

// ---------------------------------------------------------------------------------------------
// Tree

/** Children shown before "Show N more" (a view cap, not the session's limit). */
const TREE_PAGE = 8;
/** Indent per level; past level 6 the indent stops growing and the level is written instead. */
const INDENT = 14;
const INDENT_CAP = 6;

export function TreeView({ nodes, platform, path, onSelect, header }: ViewProps) {
  const [open, setOpen] = useState(() => new Set(path.map((node) => node.id)));
  const [more, setMore] = useState(() => new Set<string>());
  const selected = path[path.length - 1]?.id;
  const toggle = (id: string) =>
    setOpen((current) => {
      const next = new Set(current);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  const rows: ReactNode[] = [];
  const walk = (parent: string | null, depth: number) => {
    const items = childrenOf(nodes, parent);
    const limit = parent && !more.has(parent) ? TREE_PAGE : items.length;
    // Keep the selected path visible even past the page.
    const shown = items.filter((item, index) => index < limit || path.some((node) => node.id === item.id));
    for (const item of shown) {
      const isOpen = open.has(item.id);
      rows.push(
        <AgentRow
          key={item.id}
          node={item}
          platform={platform}
          selected={item.id === selected}
          indent={Math.min(depth, INDENT_CAP) * INDENT}
          onSelect={(node) => {
            if (node.childCount > 0) toggle(node.id);
            onSelect(node);
          }}
          lead={
            <span className="sa-disclosure" data-empty={item.childCount === 0 || undefined}>
              {item.childCount > 0 && <Chevron open={isOpen} />}
            </span>
          }
          second={
            depth > INDENT_CAP ? (
              <>
                <span className="sa-depth">L{depth}</span> {item.lastEvent}
              </>
            ) : undefined
          }
        />,
      );
      if (isOpen) walk(item.id, depth + 1);
    }
    if (parent && items.length > shown.length)
      rows.push(
        <button
          key={`${parent}-more`}
          type="button"
          className="sa-more"
          style={{ paddingInlineStart: `calc(var(--sa-row-pad) + ${Math.min(depth, INDENT_CAP) * INDENT + 18}px)` }}
          onClick={() => setMore((current) => new Set(current).add(parent))}
        >
          Show {items.length - shown.length} more
        </button>,
      );
  };
  walk(null, 0);
  return (
    <div className="sa-tree" data-platform={platform}>
      {header}
      {rows}
    </div>
  );
}

// ---------------------------------------------------------------------------------------------
// Grouped

export type GroupBy = "status" | "task" | "harness";

const STATE_ORDER: AgentState[] = ["waiting", "running", "queued", "failed", "done", "stopped"];
const KIND_ORDER: AgentKind[] = ["plan", "explore", "implement", "test", "review", "research"];
const HARNESS_ORDER: Harness[] = ["claude", "codex", "opencode", "pi"];

/** The focused session's whole family, flat, in sections; each row names its parent. */
export function GroupedView({ nodes, platform, path, onSelect, header, groupBy }: ViewProps & { groupBy: GroupBy }) {
  const root = path[0];
  const family = root ? descendants(nodes, root.id) : [];
  const byId = new Map(nodes.map((node) => [node.id, node]));
  const sections: { key: string; label: string; items: AgentNode[] }[] =
    groupBy === "status"
      ? STATE_ORDER.map((state) => ({
          key: state,
          label: STATE_LABEL[state],
          items: family.filter((node) => node.state === state),
        }))
      : groupBy === "task"
        ? KIND_ORDER.map((kind) => ({
            key: kind,
            label: KIND_LABEL[kind],
            items: family.filter((node) => node.kind === kind),
          }))
        : HARNESS_ORDER.map((harness) => ({
            key: harness,
            label: HARNESS_LABEL[harness],
            items: family.filter((node) => node.harness === harness),
          }));
  const [closed, setClosed] = useState(() => new Set(groupBy === "status" ? ["done", "stopped"] : []));
  const selected = path[path.length - 1]?.id;
  return (
    <div className="sa-grouped" data-platform={platform}>
      {root && (
        <div className="sa-grouped-root">
          <AgentRow node={root} platform={platform} selected={root.id === selected} onSelect={onSelect} />
        </div>
      )}
      {header}
      {sections
        .filter((section) => section.items.length > 0)
        .map((section) => {
          const isOpen = !closed.has(section.key);
          const items = [...section.items].sort((a, b) => a.lastEventAgo - b.lastEventAgo);
          return (
            <section key={section.key} className="sa-group" data-platform={platform}>
              <button
                type="button"
                className="sa-group-header"
                aria-expanded={isOpen}
                onClick={() =>
                  setClosed((current) => {
                    const next = new Set(current);
                    if (next.has(section.key)) next.delete(section.key);
                    else next.add(section.key);
                    return next;
                  })
                }
              >
                <Chevron open={isOpen} />
                <span>{section.label}</span>
                <span className="sa-muted">{section.items.length}</span>
              </button>
              {isOpen &&
                items.slice(0, 14).map((node) => {
                  const parent = node.parentId ? byId.get(node.parentId) : undefined;
                  return (
                    <AgentRow
                      key={node.id}
                      node={node}
                      platform={platform}
                      selected={node.id === selected}
                      onSelect={onSelect}
                      second={
                        <>
                          {groupBy !== "harness" && <HarnessMark harness={node.harness} size={12} />}
                          <span>
                            L{node.depth} · in {parent?.name ?? "session"}
                          </span>
                        </>
                      }
                    />
                  );
                })}
              {isOpen && items.length > 14 && <p className="sa-more sa-more-static">and {items.length - 14} more</p>}
            </section>
          );
        })}
    </div>
  );
}

// ---------------------------------------------------------------------------------------------
// Lanes (original idea): a timeline, one thin lane per agent, indented by depth

export function LanesView({ nodes, platform, path, onSelect, header }: ViewProps) {
  const root = path[0];
  const family = root ? [root, ...descendants(nodes, root.id)].slice(0, 60) : [];
  const span = Math.max(60, ...family.map((node) => node.startedAgo));
  const selected = path[path.length - 1]?.id;
  return (
    <div className="sa-lanes" data-platform={platform}>
      {header}
      <div className="sa-lanes-axis sa-muted">
        <span>−{ago(span)}</span>
        <span>now</span>
      </div>
      {family.map((node) => {
        const start = 1 - node.startedAgo / span;
        const endAgo =
          node.state === "running" || node.state === "waiting" ? 0 : Math.max(0, node.startedAgo - node.elapsed);
        const end = 1 - endAgo / span;
        return (
          <button
            key={node.id}
            type="button"
            className="sa-lane"
            data-state={node.state}
            data-selected={node.id === selected || undefined}
            onClick={() => onSelect(node)}
          >
            <span className="sa-lane-label" style={{ paddingInlineStart: Math.min(node.depth, 6) * 8 }}>
              <StatusMark state={node.state} size={10} label={false} />
              <span className="sa-lane-name">{node.name}</span>
            </span>
            <span className="sa-lane-track">
              <span
                className="sa-lane-bar"
                style={{ left: `${start * 100}%`, width: `${Math.max(1.5, (end - start) * 100)}%` }}
              />
            </span>
          </button>
        );
      })}
    </div>
  );
}

// ---------------------------------------------------------------------------------------------
// Stack (original idea): one level at a time, the path as a breadcrumb

export function StackView({ nodes, platform, path, onSelect, header }: ViewProps) {
  const [level, setLevel] = useState(() => Math.max(0, path.length - 1));
  const parent = level === 0 ? null : path[level - 1]!;
  const items = childrenOf(nodes, parent?.id ?? null);
  const selected = path[level]?.id;
  return (
    <div className="sa-stack" data-platform={platform}>
      <nav className="sa-crumbs" aria-label="Path">
        <button type="button" className="sa-crumb" data-current={level === 0 || undefined} onClick={() => setLevel(0)}>
          Sessions
        </button>
        {path.slice(0, -1).map((node, index) => (
          <span key={node.id} className="sa-crumb-step">
            <span className="sa-muted">›</span>
            <button
              type="button"
              className="sa-crumb"
              data-current={index + 1 === level || undefined}
              onClick={() => setLevel(index + 1)}
            >
              {node.name}
            </button>
          </span>
        ))}
      </nav>
      {parent && (
        <div className="sa-stack-parent">
          <StatusMark state={parent.state} />
          <span className="sa-row-title">{parent.name}</span>
          <span className="sa-muted">
            {items.length} subagents · L{level}
          </span>
        </div>
      )}
      {header}
      {items.map((item) => (
        <AgentRow
          key={item.id}
          node={item}
          platform={platform}
          selected={item.id === selected}
          onSelect={(node) => {
            onSelect(node);
            if (node.childCount > 0) setLevel(pathTo(nodes, node.id).length);
          }}
          trailing={
            <span className="sa-row-meta">
              {item.childCount > 0 && <span className="sa-count">{item.childCount}</span>}
              {item.childCount > 0 && <Chevron open={false} />}
            </span>
          }
        />
      ))}
    </div>
  );
}

// ---------------------------------------------------------------------------------------------
// Digest (original idea): attention first. Each session is one row with its family as a quiet
// count line; under it only the agents that need you, and the leaves that are moving now.

export function DigestView({ nodes, platform, path, onSelect, header }: ViewProps) {
  const roots = childrenOf(nodes, null);
  const selected = path[path.length - 1]?.id;
  return (
    <div className="sa-digest" data-platform={platform}>
      {roots.map((root) => {
        const family = descendants(nodes, root.id);
        const counts = stateCounts(family);
        const attention = family.filter((node) => node.state === "waiting" || node.state === "failed");
        const moving = family.filter((node) => node.state === "running" && node.childCount === 0).slice(0, 3);
        const parts = (
          [
            ["running", counts.running],
            ["waiting", counts.waiting],
            ["queued", counts.queued],
            ["failed", counts.failed],
            ["done", counts.done],
          ] as const
        ).filter(([, count]) => count > 0);
        return (
          <section key={root.id} className="sa-digest-session" data-focused={root.id === path[0]?.id || undefined}>
            <AgentRow
              node={root}
              platform={platform}
              selected={root.id === selected}
              onSelect={onSelect}
              second={
                family.length ? (
                  <span className="sa-digest-counts">
                    {parts.map(([state, count]) => (
                      <span key={state} data-state={state}>
                        <StatusMark state={state} size={10} label={false} />
                        {count}
                      </span>
                    ))}
                  </span>
                ) : (
                  root.lastEvent
                )
              }
            />
            {root.id === path[0]?.id && header}
            {[...attention, ...moving].slice(0, 5).map((node) => (
              <AgentRow
                key={node.id}
                node={node}
                platform={platform}
                selected={node.id === selected}
                onSelect={onSelect}
                indent={18}
                second={
                  <>
                    <span className="sa-muted">
                      {pathTo(nodes, node.id)
                        .slice(1, -1)
                        .map((step) => step.name)
                        .join(" › ") || root.name}
                    </span>
                  </>
                }
              />
            ))}
          </section>
        );
      })}
    </div>
  );
}
