import type {
  HiveNode,
  HivePairingInput,
  HivePairingRecord,
  HivePairingSecret,
  HivePairingSummary,
  HiveSnapshot,
  HiveWorkspace,
} from "./types";

export type HiveActorState = {
  nodes: HiveNode[];
  pairings: HivePairingRecord[];
};

export function createHiveState(): HiveActorState {
  return {
    nodes: [],
    pairings: [],
  };
}

export function hiveSnapshot(state: HiveActorState, nowUnix = currentUnixSeconds()): HiveSnapshot {
  return {
    nodes: state.nodes
      .map((node) => nodeWithResolvedPresence(node, nowUnix))
      .sort(compareNodes),
    workspaces: [],
  };
}

export function upsertHiveNode(state: HiveActorState, node: HiveNode): HiveNode {
  const index = state.nodes.findIndex((candidate) => candidate.id === node.id);
  const existing = index === -1 ? null : state.nodes[index];
  if (existing && isStaleNodeEpochUpdate(existing, node)) {
    return existing;
  }
  const resolved = mergeHiveNode(existing, node);
  if (index === -1) {
    state.nodes.push(resolved);
  } else {
    state.nodes[index] = resolved;
  }
  state.nodes.sort(compareNodes);
  return resolved;
}

export function unlinkHiveNode(state: HiveActorState, nodeID: string): HiveNode | null {
  const trimmedNodeID = nodeID.trim();
  if (!trimmedNodeID) return null;
  const index = state.nodes.findIndex((candidate) => candidate.id === trimmedNodeID);
  if (index === -1) return null;
  const [removed] = state.nodes.splice(index, 1);
  state.pairings = state.pairings.filter((pairing) => pairing.node_id !== trimmedNodeID);
  return removed ?? null;
}

export function upsertHivePairing(
  state: HiveActorState,
  input: HivePairingInput,
  nowUnix: number,
): HivePairingSummary {
  const nodeID = input.node?.id ?? input.node_id ?? null;
  const record: HivePairingRecord = {
    pairing_id: input.pairing_id,
    pairing_secret: input.pairing_secret,
    expires_at_unix: input.expires_at_unix,
    node_id: nodeID,
    created_at_unix: nowUnix,
  };
  const index = state.pairings.findIndex(
    (candidate) => candidate.pairing_id === input.pairing_id,
  );
  if (index === -1) {
    state.pairings.push(record);
  } else {
    state.pairings[index] = record;
  }
  state.pairings = state.pairings.filter(
    (candidate) => candidate.expires_at_unix > nowUnix,
  );
  return {
    pairing_id: record.pairing_id,
    expires_at_unix: record.expires_at_unix,
    node_id: record.node_id,
  };
}

export function getHivePairingSecret(
  state: HiveActorState,
  pairingID: string,
  nowUnix: number,
): HivePairingSecret | null {
  const trimmedPairingID = pairingID.trim();
  if (!trimmedPairingID) return null;
  const pairing = state.pairings.find(
    (candidate) => candidate.pairing_id === trimmedPairingID,
  );
  if (!pairing || pairing.expires_at_unix <= nowUnix) {
    return null;
  }
  return {
    pairing_id: pairing.pairing_id,
    pairing_secret: pairing.pairing_secret,
    expires_at_unix: pairing.expires_at_unix,
  };
}

function compareNodes(a: HiveNode, b: HiveNode): number {
  if (a.is_online !== b.is_online) return a.is_online ? -1 : 1;
  return a.name.localeCompare(b.name) || a.id.localeCompare(b.id);
}

function mergeHiveNode(existing: HiveNode | null, incoming: HiveNode): HiveNode {
  const restoreState = incoming.restore_state ?? existing?.restore_state ?? "ready";
  const snapshotMode = incoming.snapshot_mode ?? "incremental";
  const incomingWorkspaces = normalizeWorkspaceNodeIDs(incoming.id, incoming.workspaces);
  const tombstones = new Set(incoming.tombstone_workspace_ids ?? []);
  const shouldReplaceWorkspaces = restoreState === "ready" && snapshotMode === "full_replace";
  const workspaces = shouldReplaceWorkspaces
    ? incomingWorkspaces
    : mergeWorkspaces(existing?.workspaces ?? [], incomingWorkspaces, tombstones);

  return {
    ...(existing ?? {}),
    ...incoming,
    restore_state: restoreState,
    snapshot_mode: snapshotMode,
    workspaces,
  };
}

function mergeWorkspaces(
  existing: HiveWorkspace[],
  incoming: HiveWorkspace[],
  tombstones: Set<string>,
): HiveWorkspace[] {
  const byID = new Map<string, HiveWorkspace>();
  for (const workspace of existing) {
    if (!isTombstonedWorkspace(workspace, tombstones)) {
      byID.set(workspace.id, workspace);
    }
  }
  for (const workspace of incoming) {
    if (!isTombstonedWorkspace(workspace, tombstones)) {
      byID.set(workspace.id, workspace);
    }
  }
  return [...byID.values()].sort(compareWorkspaces);
}

function isTombstonedWorkspace(workspace: HiveWorkspace, tombstones: Set<string>): boolean {
  return tombstones.has(workspace.id) ||
    (typeof workspace.workspace_key === "string" && tombstones.has(workspace.workspace_key)) ||
    (typeof workspace.local_workspace_id === "string" && tombstones.has(workspace.local_workspace_id));
}

function normalizeWorkspaceNodeIDs(nodeID: string, workspaces: HiveWorkspace[]): HiveWorkspace[] {
  return workspaces.map((workspace) => ({
    ...workspace,
    node_id: workspace.node_id ?? nodeID,
    workspace_key: workspace.workspace_key ?? `${workspace.node_id ?? nodeID}:${workspace.local_workspace_id ?? workspace.id}`,
  }));
}

function compareWorkspaces(a: HiveWorkspace, b: HiveWorkspace): number {
  const bActivity = workspaceActivitySeconds(b);
  const aActivity = workspaceActivitySeconds(a);
  if (bActivity !== aActivity) return bActivity - aActivity;
  return a.title.localeCompare(b.title) || a.id.localeCompare(b.id);
}

function workspaceActivitySeconds(workspace: HiveWorkspace): number {
  if (typeof workspace.last_activity_unix === "number") return workspace.last_activity_unix;
  if (typeof workspace.last_activity_ms === "number") return workspace.last_activity_ms / 1_000;
  if (workspace.last_activity) {
    const parsed = Date.parse(workspace.last_activity);
    if (Number.isFinite(parsed)) return parsed / 1_000;
  }
  if (typeof workspace.updated_at_unix === "number") return workspace.updated_at_unix;
  if (typeof workspace.updated_at_ms === "number") return workspace.updated_at_ms / 1_000;
  if (workspace.updated_at) {
    const parsed = Date.parse(workspace.updated_at);
    if (Number.isFinite(parsed)) return parsed / 1_000;
  }
  return 0;
}

function isStaleNodeEpochUpdate(existing: HiveNode, incoming: HiveNode): boolean {
  if (
    typeof existing.node_started_at_unix === "number" &&
    typeof incoming.node_started_at_unix === "number" &&
    incoming.node_started_at_unix < existing.node_started_at_unix
  ) {
    return true;
  }
  return false;
}

function nodeWithResolvedPresence(node: HiveNode, nowUnix: number): HiveNode {
  if (typeof node.lease_expires_at_unix === "number" && node.lease_expires_at_unix <= nowUnix) {
    return { ...node, is_online: false };
  }
  return node;
}

function currentUnixSeconds(): number {
  return Math.floor(Date.now() / 1_000);
}
