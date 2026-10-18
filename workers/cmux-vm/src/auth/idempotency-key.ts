import { Effect } from "effect";
import type { Principal } from "../domain/principal.ts";

/** Tenant isolation is supplied by the ledger/store; service identity survives credential rotation. */
export const scopedCreationKey = (principal: Principal, key: string) =>
  Effect.promise(() => crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(
    principal.actor.kind === "service" ? ["service", principal.actor.serviceId, key] : ["key", key],
  )))).pipe(Effect.map((digest) => Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("")));
