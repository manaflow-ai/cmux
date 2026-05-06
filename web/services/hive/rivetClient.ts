import { createClient } from "rivetkit/client";
import type { registry } from "../../rivet/registry";
import { hiveActorServiceToken } from "./actor";
import type {
  HiveActorAuth,
  HiveNode,
  HivePairingInput,
  HivePairingSecret,
  HivePairingSummary,
  HiveSnapshot,
} from "./types";

export type HiveStore = {
  list(): Promise<HiveSnapshot>;
  upsertNode(node: HiveNode): Promise<HiveNode>;
  upsertPairing(input: HivePairingInput): Promise<HivePairingSummary>;
  getPairingSecret(pairingID: string, nowUnix?: number): Promise<HivePairingSecret | null>;
};

export function hiveStoreForUser(userID: string): HiveStore {
  const auth = actorAuth();
  const client = createClient<typeof registry>(hiveEndpoint());
  const actor = client.cmuxHive.getOrCreate(["user", userID]);
  return {
    list: () => actor.list(auth),
    upsertNode: (node) => actor.upsertNode(auth, node),
    upsertPairing: (input) => actor.upsertPairing(auth, input),
    getPairingSecret: (pairingID, nowUnix) =>
      actor.getPairingSecret(auth, pairingID, nowUnix),
  };
}

function actorAuth(): HiveActorAuth {
  const serviceToken = hiveActorServiceToken();
  if (!serviceToken) {
    throw new Error("CMUX_HIVE_ACTOR_TOKEN is required in production");
  }
  return { serviceToken };
}

function hiveEndpoint(): string {
  return (
    process.env.CMUX_RIVET_ENDPOINT?.trim() ||
    process.env.RIVET_ENDPOINT?.trim() ||
    process.env.NEXT_RIVET_ENDPOINT?.trim() ||
    process.env.RIVET_PUBLIC_ENDPOINT?.trim() ||
    "http://localhost:3000/api/rivet"
  );
}
