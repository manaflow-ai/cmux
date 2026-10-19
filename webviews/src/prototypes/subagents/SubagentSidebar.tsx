// l10n-allow-file: gallery prototype (sample labels), not shipped UI.
// The sidebar hierarchy prototype: a session family (agents that start subagents that start their
// own) in one of six layouts, on the Mac (cmux-next window) or the iPhone (cnx-ios). Click a row to
// select it; the Limits button opens the session's limit panel; `settings` shows the defaults.
import { useMemo, useState } from "react";
import { LimitLine, LimitsPanel, LimitsSettings } from "./limits";
import { buildForest, childrenOf, deepestRunningPath, descendants, HARNESS_LABEL, pathTo, STATE_LABEL, type AgentNode } from "./hierarchy";
import { GlassCircle, HarnessMark, MacWindow, Phone, Shimmer, StatusMark, type Platform } from "./parts";
import {
  ColumnsView,
  columnsWidth,
  DigestView,
  GroupedView,
  LanesView,
  StackView,
  TreeView,
  type GroupBy,
  type ViewProps,
} from "./views";
import "./subagents.css";

export type SidebarLayout = "columns" | "tree" | "grouped" | "lanes" | "stack" | "digest";

export type SubagentSidebarProps = {
  platform: Platform;
  layout: SidebarLayout;
  groupBy?: GroupBy;
  /** Subagents of the focused session's root (the width in use). */
  fanout: number;
  /** Levels of the focused family. */
  depth: number;
  /** Columns that show in full (Mac columns layout). */
  visibleColumns?: number;
  /** The focused session's limits (width, depth); default 50 and 10. */
  limitWidth?: number;
  limitDepth?: number;
  limitsOpen?: boolean;
  settings?: boolean;
  /** How deep the first selection goes (default: the visible columns, or the deepest live agent). */
  focusDepth?: number;
};

const SIDEBAR_WIDTH: Record<SidebarLayout, number> = {
  columns: 0,
  tree: 288,
  grouped: 288,
  lanes: 360,
  stack: 288,
  digest: 288,
};

export function SubagentSidebar({
  platform,
  layout,
  groupBy = "status",
  fanout,
  depth,
  visibleColumns = 3,
  limitWidth = 50,
  limitDepth = 10,
  limitsOpen = false,
  settings = false,
  focusDepth,
}: SubagentSidebarProps) {
  const nodes = useMemo(
    () =>
      buildForest({
        children: fanout,
        depth,
        ...((limitWidth !== 50 || limitDepth !== 10) && { limits: { width: limitWidth, depth: limitDepth } }),
      }),
    [fanout, depth, limitWidth, limitDepth],
  );
  // Columns start on the widest levels (the root's children in the first full column); a deep
  // variant asks for more with focusDepth.
  const [path, setPath] = useState<AgentNode[]>(() =>
    deepestRunningPath(nodes).slice(0, focusDepth ?? (layout === "columns" || layout === "tree" ? visibleColumns : 99)),
  );
  const [panel, setPanel] = useState(limitsOpen);
  const root = path[0] ?? nodes[0]!;
  const family = descendants(nodes, root.id);
  const deepest = Math.max(0, ...family.map((node) => node.depth));
  const refused = root.refused ?? 0;
  const header = (
    <div className="sa-limit-wrap">
      <LimitLine
        used={childrenOf(nodes, root.id).length}
        depth={deepest}
        limits={root.limits}
        refused={refused}
        open={panel}
        onOpen={() => setPanel((open) => !open)}
      />
      {panel && (
        <LimitsPanel
          key={root.id}
          session={root}
          platform={platform}
          finished={childrenOf(nodes, root.id).filter((node) => node.state === "done" || node.state === "stopped").length}
        />
      )}
    </div>
  );
  const select = (node: AgentNode) => setPath(pathTo(nodes, node.id));
  const props: ViewProps = { nodes, platform, path, onSelect: select, header };
  const view =
    layout === "columns" ? (
      <ColumnsView {...props} visible={visibleColumns} />
    ) : layout === "tree" ? (
      <TreeView {...props} />
    ) : layout === "grouped" ? (
      <GroupedView {...props} groupBy={groupBy} />
    ) : layout === "lanes" ? (
      <LanesView {...props} />
    ) : layout === "stack" ? (
      <StackView {...props} />
    ) : (
      <DigestView {...props} />
    );
  const selected = path[path.length - 1] ?? root;

  if (platform === "iphone")
    return (
      <Phone
        toolbar={
          <>
            <GlassCircle glyph={layout === "stack" || layout === "columns" ? "back" : "menu"} label="Back" />
            <span className="sa-phone-title">
              <strong>{settings ? "Subagents" : root.name}</strong>
              {!settings && (
                <span className="sa-muted">
                  {family.length} subagents · {root.workspace}
                </span>
              )}
            </span>
            <GlassCircle glyph="more" label="More" />
          </>
        }
      >
        {settings ? <LimitsSettings platform={platform} /> : view}
      </Phone>
    );

  const levels = 1 + path.filter((node) => childrenOf(nodes, node.id).length > 0).length;
  const width = layout === "columns" ? columnsWidth(levels, visibleColumns) : SIDEBAR_WIDTH[layout];
  return (
    <MacWindow title={settings ? "Settings › Agents" : root.workspace} sidebar={view} sidebarWidth={width}>
      {settings ? <LimitsSettings platform={platform} /> : <AgentDetail node={selected} nodes={nodes} />}
    </MacWindow>
  );
}

/** The selected agent's pane: its path, who started it, its task and its newest events. */
function AgentDetail({ node, nodes }: { node: AgentNode; nodes: readonly AgentNode[] }) {
  const path = pathTo(nodes, node.id);
  const kids = childrenOf(nodes, node.id);
  return (
    <article className="sa-detail">
      <nav className="sa-crumbs" aria-label="Path">
        {path.map((step, index) => (
          <span key={step.id} className="sa-crumb-step">
            {index > 0 && <span className="sa-muted">›</span>}
            <span className="sa-crumb" data-current={step.id === node.id || undefined}>
              {step.name}
            </span>
          </span>
        ))}
      </nav>
      <header className="sa-detail-header">
        <h1>{node.name}</h1>
        <p className="sa-muted">
          <HarnessMark harness={node.harness} size={14} /> {HARNESS_LABEL[node.harness]} · {STATE_LABEL[node.state]} · started by{" "}
          {node.startedBy} · level {node.depth}
        </p>
      </header>
      <div className="sa-bubble">{node.task}</div>
      <div className="sa-detail-events">
        {node.state === "running" ? <Shimmer as="div">{node.lastEvent}</Shimmer> : <div>{node.lastEvent}</div>}
        <div className="sa-muted">{kids.length > 0 ? `Started ${kids.length} subagents` : "No subagents"}</div>
      </div>
      {kids.length > 0 && (
        <div className="sa-detail-kids">
          {kids.slice(0, 12).map((kid) => (
            <span key={kid.id} className="sa-chip" data-state={kid.state}>
              <StatusMark state={kid.state} label={false} />
              {kid.name}
            </span>
          ))}
          {kids.length > 12 && <span className="sa-chip sa-muted">+{kids.length - 12}</span>}
        </div>
      )}
    </article>
  );
}
