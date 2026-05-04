import { timingSafeEqual } from "node:crypto";
import { actor, UserError } from "rivetkit";
import {
  hiveNodeInputSchema,
  hivePairingInputSchema,
  type HiveActorAuth,
  type HivePairingSecret,
  type HivePairingSummary,
  type HiveSnapshot,
} from "./types";
import {
  createHiveState,
  getHivePairingSecret,
  hiveSnapshot,
  upsertHiveNode,
  upsertHivePairing,
} from "./state";

export const cmuxHive = actor({
  createState: createHiveState,
  actions: {
    list(c, auth: HiveActorAuth): HiveSnapshot {
      assertActorAuth(auth);
      return hiveSnapshot(c.state);
    },

    upsertNode(c, auth: HiveActorAuth, input: unknown) {
      assertActorAuth(auth);
      const node = hiveNodeInputSchema.parse(input);
      return upsertHiveNode(c.state, node);
    },

    upsertPairing(c, auth: HiveActorAuth, input: unknown): HivePairingSummary {
      assertActorAuth(auth);
      const parsed = hivePairingInputSchema.parse(input);
      const nowUnix = currentUnixSeconds();
      if (parsed.expires_at_unix <= nowUnix) {
        throw new UserError("Pairing is expired", { code: "pairing_expired" });
      }
      if (parsed.node) {
        upsertHiveNode(c.state, parsed.node);
      }
      return upsertHivePairing(c.state, parsed, nowUnix);
    },

    getPairingSecret(
      c,
      auth: HiveActorAuth,
      pairingID: string,
      nowUnix = currentUnixSeconds(),
    ): HivePairingSecret | null {
      assertActorAuth(auth);
      const trimmedPairingID = pairingID.trim();
      if (!trimmedPairingID) {
        throw new UserError("Missing pairing id", { code: "missing_pairing_id" });
      }
      return getHivePairingSecret(c.state, trimmedPairingID, nowUnix);
    },
  },
});

function assertActorAuth(auth: HiveActorAuth): void {
  const expected = hiveActorServiceToken();
  if (!expected || !timingSafeStringEqual(auth?.serviceToken ?? "", expected)) {
    throw new UserError("Forbidden", { code: "forbidden" });
  }
}

function timingSafeStringEqual(actual: string, expected: string): boolean {
  const actualBytes = Buffer.from(actual);
  const expectedBytes = Buffer.from(expected);
  if (actualBytes.length !== expectedBytes.length) return false;
  return timingSafeEqual(actualBytes, expectedBytes);
}

export function hiveActorServiceToken(): string | null {
  const configured = process.env.CMUX_HIVE_ACTOR_TOKEN?.trim();
  if (configured) return configured;
  if (process.env.NODE_ENV === "production") return null;
  return "cmux-hive-dev-actor-token";
}

function currentUnixSeconds(): number {
  return Math.floor(Date.now() / 1000);
}
