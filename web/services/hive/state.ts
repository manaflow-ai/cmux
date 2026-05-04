import type {
  HiveNode,
  HivePairingInput,
  HivePairingRecord,
  HivePairingSecret,
  HivePairingSummary,
  HiveSnapshot,
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

export function hiveSnapshot(state: HiveActorState): HiveSnapshot {
  return {
    nodes: state.nodes,
    workspaces: [],
  };
}

export function upsertHiveNode(state: HiveActorState, node: HiveNode): HiveNode {
  const index = state.nodes.findIndex((candidate) => candidate.id === node.id);
  if (index === -1) {
    state.nodes.push(node);
  } else {
    state.nodes[index] = node;
  }
  state.nodes.sort(compareNodes);
  return node;
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

