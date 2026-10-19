// l10n-allow-file: gallery prototype fixtures (sample agent names and tasks), not shipped UI.
// The session hierarchy the subagent prototypes draw: agents start subagents, which start their
// own. The shape follows the fields the acpmux spawn tools will carry (plans/cmux-next/subagents,
// depth, children; status and indicator; subsessionLimits with their source) through the brief's fields: id, parentId, name, startedBy, depth, harness, state, lastEvent,
// childCount, limits {width, depth}. Everything here is deterministic (no Math.random, no clock),
// so a screenshot of a variant is the same on every run.

export type Harness = "claude" | "codex" | "opencode" | "pi";
export type AgentState = "running" | "waiting" | "queued" | "done" | "failed" | "stopped";
export type AgentKind = "plan" | "explore" | "implement" | "test" | "review" | "research";

export type Limits = { width: number; depth: number };

export type AgentNode = {
  id: string;
  parentId: string | null;
  name: string;
  /** Who started it: "you" for a root, else the parent's name. */
  startedBy: string;
  depth: number;
  harness: Harness;
  state: AgentState;
  kind: AgentKind;
  /** The task it was given, one line. */
  task: string;
  /** The newest event, as the row shows it ("Ran bun test src/net"). */
  lastEvent: string;
  /** Seconds since lastEvent. */
  lastEventAgo: number;
  /** Seconds it has run (or ran). */
  elapsed: number;
  /** Started this many seconds before now (the lanes view). */
  startedAgo: number;
  childCount: number;
  /** The session's limits; a root carries them, children inherit unless raised. */
  limits: Limits;
  /** The workspace (a repo) it works in. */
  workspace: string;
  /** It asked for subagents past the depth limit, and the daemon refused (subsessions.depth_limit). */
  blocked?: "depth";
  /** Starts the daemon refused at the width limit (subsessions.width_limit); a closed child frees a slot. */
  refused?: number;
  /** Where the limits come from (PROTOCOL.md `maxChildrenSource`). */
  limitsSource: "session" | "inherited" | "settings" | "default";
};

/** The user setting: every new session starts with these limits. */
export const DEFAULT_LIMITS: Limits = { width: 50, depth: 10 };

export const HARNESS_LABEL: Record<Harness, string> = {
  claude: "Claude",
  codex: "Codex",
  opencode: "OpenCode",
  pi: "Pi",
};

export const STATE_LABEL: Record<AgentState, string> = {
  running: "Running",
  waiting: "Needs you",
  queued: "Queued",
  done: "Done",
  failed: "Failed",
  stopped: "Stopped",
};

export const KIND_LABEL: Record<AgentKind, string> = {
  plan: "Plan",
  explore: "Explore",
  implement: "Implement",
  test: "Test",
  review: "Review",
  research: "Research",
};

/** Top-level sessions (what the user started), one per workspace task. */
const ROOTS: { name: string; task: string; workspace: string; harness: Harness; state: AgentState }[] = [
  { name: "Ship offline sync", task: "Make the iOS app work offline and sync on reconnect", workspace: "cnx-ios", harness: "claude", state: "running" },
  { name: "Audit fetch helper", task: "Retries, errors, timeouts and tests for src/net", workspace: "cmux", harness: "codex", state: "running" },
  { name: "Port sidebar to Rust", task: "Move the sidebar store into the daemon", workspace: "cmux-tui", harness: "claude", state: "waiting" },
  { name: "Fix flaky CI", task: "Find why cmux-tui.yml fails 1 in 8 runs", workspace: "cmux", harness: "codex", state: "done" },
  { name: "Release notes 0.64", task: "Draft the changelog from merged PRs", workspace: "cmux", harness: "opencode", state: "done" },
  { name: "Billing page polish", task: "Tighten the Cloud billing page", workspace: "web", harness: "pi", state: "failed" },
];

/** Child tasks by depth: depth 1 splits the job, deeper levels split a part. */
const SPLITS: { name: string; kind: AgentKind; event: string }[][] = [
  [
    { name: "Map the code", kind: "explore", event: "Read 14 files in Sources/Sync" },
    { name: "Write the plan", kind: "plan", event: "Wrote PLAN.md (6 steps)" },
    { name: "Queue store", kind: "implement", event: "Edited OutboxStore.swift +84 −12" },
    { name: "Conflict rules", kind: "implement", event: "Edited Merge.swift +40 −3" },
    { name: "Reconnect tests", kind: "test", event: "Ran swift test --filter Reconnect" },
    { name: "Review the diff", kind: "review", event: "Left 3 notes on Outbox.swift" },
    { name: "Prior art", kind: "research", event: "Searched the web for CRDT outbox" },
    { name: "Migration", kind: "implement", event: "Edited Schema.swift +22 −0" },
  ],
  [
    { name: "Read call sites", kind: "explore", event: "Searched for enqueue( (31 hits)" },
    { name: "Draft API", kind: "plan", event: "Wrote 3 signatures" },
    { name: "Edit module", kind: "implement", event: "Edited Queue.swift +18 −4" },
    { name: "Unit check", kind: "test", event: "Ran bun test src/net/retry" },
    { name: "Check edge cases", kind: "review", event: "Found 2 unhandled errors" },
    { name: "Benchmarks", kind: "test", event: "Ran hyperfine (p50 4.1 ms)" },
  ],
  [
    { name: "Grep usages", kind: "explore", event: "Searched for RetryPolicy" },
    { name: "Patch file", kind: "implement", event: "Edited retry.ts +6 −2" },
    { name: "Verify", kind: "test", event: "Ran tsc --noEmit" },
    { name: "Second opinion", kind: "review", event: "Agreed with the patch" },
    { name: "Trace a bug", kind: "explore", event: "Read the crash log (3 frames)" },
    { name: "Fix lint", kind: "implement", event: "Edited 2 files +4 −4" },
    { name: "Read docs", kind: "research", event: "Read the SQLite WAL page" },
  ],
];

const HARNESS_CYCLE: Harness[] = ["claude", "codex", "claude", "opencode", "codex", "pi"];
const STATE_CYCLE: AgentState[] = ["running", "done", "running", "queued", "done", "waiting", "done", "failed", "running", "done", "stopped"];

export type ForestOptions = {
  /** Children of each node on the first level of the focused root (the width). */
  children: number;
  /** Levels below the root (1 = only direct subagents). */
  depth: number;
  /** Children of deeper nodes (they taper); default 3. */
  innerFanout?: number;
  /** The focused root's limits (what its session allows). */
  limits?: Limits;
};

/** A hash of a string, for deterministic picks. */
function hash(text: string): number {
  let value = 2166136261;
  for (let index = 0; index < text.length; index += 1) {
    value ^= text.charCodeAt(index);
    value = Math.imul(value, 16777619);
  }
  return value >>> 0;
}

/**
 * The forest: six root sessions; the first (the focused one) has `children` subagents, each with
 * a tapering subtree down to `depth`; the other roots have small trees of their own.
 */
export function buildForest(options: ForestOptions): AgentNode[] {
  const nodes: AgentNode[] = [];
  const limits = options.limits ?? DEFAULT_LIMITS;
  const inner = options.innerFanout ?? 4;
  const add = (
    parent: AgentNode | null,
    root: (typeof ROOTS)[number],
    index: number,
    depth: number,
    maxDepth: number,
    width: number,
    spine: boolean,
  ): AgentNode => {
    const pool = SPLITS[Math.min(depth - 1, SPLITS.length - 1)] ?? SPLITS[0]!;
    // Offset each parent's picks so a child never repeats its parent's or its siblings' task.
    const offset = parent ? hash(parent.id) % pool.length : 0;
    let slot = (index + offset) % pool.length;
    if (parent && pool[slot]!.name === parent.name.replace(/ \d+$/, "")) slot = (slot + 1) % pool.length;
    const pick = parent ? pool[slot]! : undefined;
    const id = parent ? `${parent.id}.${index + 1}` : `s${ROOTS.indexOf(root) + 1}`;
    const seed = hash(id);
    const round = Math.floor(index / pool.length);
    const name = parent ? `${pick!.name}${round > 0 ? ` ${round + 1}` : ""}` : root.name;
    // A finished parent's children are finished; a running one has a mix.
    const parentState = parent?.state ?? root.state;
    let state: AgentState = parent ? STATE_CYCLE[seed % STATE_CYCLE.length]! : root.state;
    if (parent && (parentState === "done" || parentState === "stopped")) state = seed % 5 === 0 ? "stopped" : "done";
    if (parent && parentState === "failed" && seed % 3 === 0) state = "failed";
    if (parent && depth === maxDepth && state === "queued") state = "running";
    const sessionLimits = parent ? parent.limits : root === ROOTS[0] ? limits : DEFAULT_LIMITS;
    const elapsed = 20 + (seed % 900);
    const node: AgentNode = {
      id,
      parentId: parent?.id ?? null,
      name,
      startedBy: parent ? parent.name : "you",
      depth,
      harness: parent ? HARNESS_CYCLE[(seed >> 3) % HARNESS_CYCLE.length]! : root.harness,
      state,
      kind: pick?.kind ?? "plan",
      task: parent ? `${pick!.name} for “${parent.name}”` : root.task,
      lastEvent: pick?.event ?? root.task,
      lastEventAgo: state === "running" ? seed % 40 : 60 + (seed % 3000),
      elapsed,
      startedAgo: elapsed + (state === "running" ? 0 : 30 + (seed % 600)),
      childCount: 0,
      limits: sessionLimits,
      workspace: root.workspace,
      limitsSource: parent ? "inherited" : root === ROOTS[0] && options.limits ? "session" : "settings",
    };
    nodes.push(node);
    const tapered = depth === 0 ? width : Math.max(spine ? 1 : 0, inner - (depth >> 1) - (seed % 2));
    if (depth < maxDepth && depth < sessionLimits.depth) {
      // Width counts open children: starts past the limit are refused, not queued.
      const open = Math.min(tapered, sessionLimits.width);
      for (let child = 0; child < open; child += 1)
        add(node, root, child, depth + 1, maxDepth, width, spine && child === 0);
      node.childCount = open;
      if (tapered > open) {
        node.refused = tapered - open;
        node.lastEvent = `${tapered - open} starts refused (limit ${sessionLimits.width} open)`;
      }
    } else if (spine && depth >= sessionLimits.depth && depth < maxDepth) {
      // It asked for subagents past the depth limit: none start, and the row says why.
      node.blocked = "depth";
      node.lastEvent = `Could not start subagents (depth limit ${sessionLimits.depth})`;
      node.state = "waiting";
    }
    return node;
  };
  ROOTS.forEach((root, index) => {
    if (index === 0) add(null, root, 0, 0, options.depth, options.children, true);
    else add(null, root, 0, 0, Math.min(2, options.depth), [4, 3, 6, 2, 3][index - 1]!, false);
  });
  return nodes;
}

/** Children of `id`, in start order. */
export function childrenOf(nodes: readonly AgentNode[], id: string | null): AgentNode[] {
  return nodes.filter((node) => node.parentId === id);
}

/** The chain from the root to `id`. */
export function pathTo(nodes: readonly AgentNode[], id: string): AgentNode[] {
  const byId = new Map(nodes.map((node) => [node.id, node]));
  const path: AgentNode[] = [];
  for (let node = byId.get(id); node; node = node.parentId ? byId.get(node.parentId) : undefined) path.unshift(node);
  return path;
}

/** Every descendant of `id` (not `id` itself). */
export function descendants(nodes: readonly AgentNode[], id: string): AgentNode[] {
  const out: AgentNode[] = [];
  const walk = (parent: string) => {
    for (const child of childrenOf(nodes, parent)) {
      out.push(child);
      walk(child.id);
    }
  };
  walk(id);
  return out;
}

/** Count by state of a subtree (a root's whole family). */
export function stateCounts(nodes: readonly AgentNode[]): Record<AgentState, number> {
  const counts: Record<AgentState, number> = { running: 0, waiting: 0, queued: 0, done: 0, failed: 0, stopped: 0 };
  for (const node of nodes) counts[node.state] += 1;
  return counts;
}

/** "12s", "4m", "2h". */
export function ago(seconds: number): string {
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  return `${Math.floor(seconds / 3600)}h`;
}

/** The deepest running (or waiting) agent's path in a root's family: the default selection. */
export function deepestRunningPath(nodes: readonly AgentNode[], rootId = "s1"): AgentNode[] {
  const live = descendants(nodes, rootId).filter((node) => node.state === "running" || node.state === "waiting");
  const best = live.reduce<AgentNode | undefined>((pick, node) => (!pick || node.depth > pick.depth ? node : pick), undefined);
  return pathTo(nodes, best?.id ?? rootId);
}
