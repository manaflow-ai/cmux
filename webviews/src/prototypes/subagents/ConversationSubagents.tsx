// l10n-allow-file: gallery prototype (sample transcript), not shipped UI.
// Subagents inside a conversation: when the agent starts children, the transcript shows them as
// compact chips, cards, one summary line, a nested tree, or tool rows, each with live state. A
// click opens the child in place, with its parent as the back target.
import { useMemo, useState } from "react";
import { ago, buildForest, childrenOf, descendants, HARNESS_LABEL, stateCounts, STATE_LABEL, type AgentNode, type AgentState } from "./hierarchy";
import { Chevron, GlassCircle, HarnessMark, MacWindow, Phone, Shimmer, StatusMark, type Platform } from "./parts";
import "./subagents.css";

export type InlineDesign = "chips" | "cards" | "line" | "tree" | "toolrows";

export type ConversationSubagentsProps = {
  platform: Platform;
  design: InlineDesign;
  /** Subagents the turn started. */
  count: number;
  /** `live`: a running mix; `finished`: every child is done. */
  phase?: "live" | "finished";
  /** Open the first child (the view a click leads to). */
  opened?: boolean;
};

function finish(node: AgentNode): AgentNode {
  return node.state === "running" || node.state === "queued" || node.state === "waiting"
    ? { ...node, state: "done", lastEventAgo: 40 + node.lastEventAgo }
    : node;
}

export function ConversationSubagents({ platform, design, count, phase = "live", opened = false }: ConversationSubagentsProps) {
  const nodes = useMemo(() => {
    const forest = buildForest({ children: count, depth: 3 });
    return phase === "finished" ? forest.map(finish) : forest;
  }, [count, phase]);
  const parent = nodes[0]!;
  const kids = childrenOf(nodes, parent.id);
  const [open, setOpen] = useState<AgentNode | null>(opened ? (kids[0] ?? null) : null);
  const transcript = open ? (
    <ChildView child={open} parent={parent} nodes={nodes} onBack={() => setOpen(null)} platform={platform} />
  ) : (
    <Transcript platform={platform} parent={parent} kids={kids} nodes={nodes} design={design} onOpen={setOpen} phase={phase} />
  );
  if (platform === "iphone")
    return (
      <Phone
        toolbar={
          <>
            <GlassCircle glyph="back" label="Back" />
            <span className="sa-phone-title">
              <strong>{open ? open.name : parent.name}</strong>
              <span className="sa-muted">{open ? `Subagent of ${parent.name}` : `Claude · ${parent.workspace}`}</span>
            </span>
            <GlassCircle glyph="more" label="More" />
          </>
        }
      >
        <div className="sa-chat" data-platform="iphone">
          {transcript}
        </div>
        <div className="sa-phone-composer">
          <span className="sa-muted">Follow up</span>
          <span className="sa-send" aria-hidden="true" />
        </div>
      </Phone>
    );
  return (
    <MacWindow title={parent.workspace} sidebarWidth={220} sidebar={<MiniSidebar nodes={nodes} current={open ?? parent} />}>
      <div className="sa-chat" data-platform="mac">
        {transcript}
      </div>
    </MacWindow>
  );
}

/** A plain session list for context (the sidebar layouts are their own entry). */
function MiniSidebar({ nodes, current }: { nodes: readonly AgentNode[]; current: AgentNode }) {
  return (
    <div className="sa-tree" data-platform="mac">
      {childrenOf(nodes, null).map((root) => (
        <div key={root.id} className="sa-row" data-platform="mac" data-selected={root.id === current.id || current.id.startsWith(`${root.id}.`) || undefined}>
          <StatusMark state={root.state} />
          <span className="sa-row-text">
            <span className="sa-row-title">{root.name}</span>
          </span>
          <span className="sa-row-meta">{descendants(nodes, root.id).length || ""}</span>
        </div>
      ))}
    </div>
  );
}

function Transcript({
  platform,
  parent,
  kids,
  nodes,
  design,
  onOpen,
  phase,
}: {
  platform: Platform;
  parent: AgentNode;
  kids: AgentNode[];
  nodes: readonly AgentNode[];
  design: InlineDesign;
  onOpen: (node: AgentNode) => void;
  phase: "live" | "finished";
}) {
  return (
    <>
      <div className="sa-bubble sa-bubble-user">{parent.task}. Split it up and run the parts at once.</div>
      <p className="sa-prose">
        I’ll map the sync code first, then run the queue, conflict rules and tests as separate subagents so they
        work at the same time.
      </p>
      <SpawnBlock design={design} kids={kids} nodes={nodes} onOpen={onOpen} platform={platform} />
      {phase === "live" ? (
        <p className="sa-prose sa-muted">
          <Shimmer>Waiting on {kids.filter((kid) => kid.state === "running").length} subagents</Shimmer>
        </p>
      ) : (
        <p className="sa-prose">All {kids.length} subagents finished. The outbox now survives a restart; reconnect replays it in order.</p>
      )}
    </>
  );
}

const SHOWN = { chips: 10, cards: 6, tree: 8, toolrows: 6, line: 8 } as const;

function SpawnBlock({
  design,
  kids,
  nodes,
  onOpen,
  platform,
}: {
  design: InlineDesign;
  kids: AgentNode[];
  nodes: readonly AgentNode[];
  onOpen: (node: AgentNode) => void;
  platform: Platform;
}) {
  const [expanded, setExpanded] = useState(design !== "line");
  const counts = stateCounts(kids);
  const summary = (["running", "waiting", "failed", "done", "queued"] as AgentState[])
    .filter((state) => counts[state] > 0)
    .map((state) => `${counts[state]} ${STATE_LABEL[state].toLowerCase()}`)
    .join(" · ");
  const shown = kids.slice(0, SHOWN[design]);
  const rest = kids.length - shown.length;
  switch (design) {
    case "chips":
      return (
        <div className="sa-spawn" data-design="chips">
          <div className="sa-spawn-head sa-muted">
            Started {kids.length} subagents · {summary}
          </div>
          <div className="sa-chips">
            {shown.map((kid) => (
              <button key={kid.id} type="button" className="sa-chip" data-state={kid.state} onClick={() => onOpen(kid)}>
                <StatusMark state={kid.state} label={false} />
                <span>{kid.name}</span>
                {kid.state === "running" && <span className="sa-muted">{ago(kid.elapsed)}</span>}
              </button>
            ))}
            {rest > 0 && <span className="sa-chip sa-muted">+{rest}</span>}
          </div>
        </div>
      );
    case "cards":
      return (
        <div className="sa-spawn" data-design="cards">
          <div className="sa-spawn-head sa-muted">
            Started {kids.length} subagents · {summary}
          </div>
          <div className="sa-cards" data-platform={platform}>
            {shown.map((kid) => {
              const sub = descendants(nodes, kid.id);
              const done = sub.filter((node) => node.state === "done").length;
              return (
                <button key={kid.id} type="button" className="sa-card" data-state={kid.state} onClick={() => onOpen(kid)}>
                  <span className="sa-card-top">
                    <StatusMark state={kid.state} />
                    <span className="sa-row-title">{kid.name}</span>
                    <HarnessMark harness={kid.harness} size={14} />
                  </span>
                  <span className="sa-card-event">
                    {kid.state === "running" ? <Shimmer>{kid.lastEvent}</Shimmer> : kid.lastEvent}
                  </span>
                  <span className="sa-card-foot sa-muted">
                    {sub.length > 0 ? `${done}/${sub.length} subagents done` : HARNESS_LABEL[kid.harness]} · {ago(kid.elapsed)}
                  </span>
                  {sub.length > 0 && (
                    <span className="sa-progress" aria-hidden="true">
                      <span style={{ width: `${(done / sub.length) * 100}%` }} />
                    </span>
                  )}
                </button>
              );
            })}
          </div>
          {rest > 0 && <div className="sa-more sa-more-static">and {rest} more</div>}
        </div>
      );
    case "line":
      return (
        <div className="sa-spawn" data-design="line">
          <button type="button" className="sa-spawn-line" aria-expanded={expanded} onClick={() => setExpanded((value) => !value)}>
            <span className="sa-stacked-marks" aria-hidden="true">
              {kids.slice(0, 6).map((kid) => (
                <StatusMark key={kid.id} state={kid.state} label={false} />
              ))}
            </span>
            <span>
              {kids.length} subagents · {summary}
            </span>
            <Chevron open={expanded} />
          </button>
          {expanded && (
            <div className="sa-spawn-list">
              {shown.map((kid) => (
                <button key={kid.id} type="button" className="sa-spawn-item" onClick={() => onOpen(kid)}>
                  <StatusMark state={kid.state} />
                  <span className="sa-row-title">{kid.name}</span>
                  <span className="sa-muted sa-ellipsis">{kid.state === "running" ? <Shimmer>{kid.lastEvent}</Shimmer> : kid.lastEvent}</span>
                </button>
              ))}
              {rest > 0 && <div className="sa-more sa-more-static">and {rest} more</div>}
            </div>
          )}
        </div>
      );
    case "tree":
      return (
        <div className="sa-spawn sa-spawn-card" data-design="tree">
          <div className="sa-spawn-head sa-muted">
            Started {kids.length} subagents ({descendants(nodes, kids[0]?.parentId ?? "").length} in all)
          </div>
          {shown.map((kid) => (
            <InlineTreeRow key={kid.id} node={kid} nodes={nodes} level={0} onOpen={onOpen} />
          ))}
          {rest > 0 && <div className="sa-more sa-more-static">and {rest} more</div>}
        </div>
      );
    case "toolrows":
      return (
        <div className="sa-spawn" data-design="toolrows">
          <button type="button" className="sa-toolrow" aria-expanded={expanded} onClick={() => setExpanded((value) => !value)}>
            <PeopleGlyph />
            <span>
              Started {kids.length} subagents{counts.running ? `, ${counts.running} running` : ""}
            </span>
            <Chevron open={expanded} />
          </button>
          {expanded &&
            shown.map((kid) => (
              <button key={kid.id} type="button" className="sa-toolrow sa-toolrow-child" onClick={() => onOpen(kid)}>
                <StatusMark state={kid.state} />
                <span>
                  {kid.state === "running" ? <Shimmer>{kid.name}</Shimmer> : kid.name}
                  <span className="sa-muted"> · {kid.lastEvent}</span>
                </span>
              </button>
            ))}
          {expanded && rest > 0 && <div className="sa-more sa-more-static">and {rest} more</div>}
        </div>
      );
  }
}

function InlineTreeRow({
  node,
  nodes,
  level,
  onOpen,
}: {
  node: AgentNode;
  nodes: readonly AgentNode[];
  level: number;
  onOpen: (node: AgentNode) => void;
}) {
  const [open, setOpen] = useState(level === 0 && node.state === "running");
  const kids = childrenOf(nodes, node.id);
  return (
    <>
      <div className="sa-inline-tree-row" style={{ paddingInlineStart: level * 16 }}>
        <button type="button" className="sa-disclosure" aria-label={open ? "Collapse" : "Expand"} disabled={!kids.length} onClick={() => setOpen((value) => !value)}>
          {kids.length > 0 && <Chevron open={open} />}
        </button>
        <button type="button" className="sa-inline-tree-open" onClick={() => onOpen(node)}>
          <StatusMark state={node.state} />
          <span className="sa-row-title">{node.name}</span>
          <span className="sa-muted sa-ellipsis">{node.state === "running" ? <Shimmer>{node.lastEvent}</Shimmer> : node.lastEvent}</span>
          {kids.length > 0 && <span className="sa-count">{kids.length}</span>}
        </button>
      </div>
      {open && kids.slice(0, 4).map((kid) => <InlineTreeRow key={kid.id} node={kid} nodes={nodes} level={level + 1} onOpen={onOpen} />)}
    </>
  );
}

function PeopleGlyph() {
  return (
    <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
      <circle cx="6" cy="5.5" r="2.5" fill="none" stroke="currentColor" strokeWidth="1.3" />
      <circle cx="11.5" cy="6" r="2" fill="none" stroke="currentColor" strokeWidth="1.3" />
      <path d="M1.5 13.5c.6-2.4 2.3-3.6 4.5-3.6s3.9 1.2 4.5 3.6M10.5 10c1.9 0 3.3.9 4 3" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
    </svg>
  );
}

/** The child opened in place: a back line to the parent, then the child's own turn. */
function ChildView({
  child,
  parent,
  nodes,
  onBack,
  platform,
}: {
  child: AgentNode;
  parent: AgentNode;
  nodes: readonly AgentNode[];
  onBack: () => void;
  platform: Platform;
}) {
  const kids = childrenOf(nodes, child.id);
  return (
    <>
      {platform === "mac" && (
        <button type="button" className="sa-backline" onClick={onBack}>
          <span aria-hidden="true">‹</span> Subagent of <strong>{parent.name}</strong>
          <span className="sa-muted">
            · {HARNESS_LABEL[child.harness]} · {STATE_LABEL[child.state]}
          </span>
        </button>
      )}
      <div className="sa-bubble sa-bubble-task">
        <span className="sa-muted">Task from {parent.name}</span>
        {child.task}
      </div>
      <p className="sa-prose">I read the call sites first, then I’ll split the edit and the check into two subagents.</p>
      {kids.length > 0 && <SpawnBlock design="chips" kids={kids} nodes={nodes} onOpen={() => undefined} platform={platform} />}
      <p className="sa-prose sa-muted">{child.state === "running" ? <Shimmer>{child.lastEvent}</Shimmer> : child.lastEvent}</p>
    </>
  );
}
