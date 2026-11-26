import { Effect } from "effect";
import type { Principal } from "../domain/principal.ts";

/**
 * A creation key as a client sent it, or one already scoped (read back from the caller's own tenant ledger by the
 * server, never from a request). Every read through it still checks the caller against the retained intent.
 */
export type CreationKey = string | { readonly scoped: string };

/** Tenant isolation is supplied by the ledger/store; service identity survives credential rotation. */
export const scopedCreationKey = (principal: Principal, key: CreationKey): Effect.Effect<string> => typeof key !== "string" ? Effect.succeed(key.scoped) :
  Effect.promise(() => crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(
    principal.actor.kind === "service" ? ["service", principal.actor.serviceId, key] : ["key", key],
  )))).pipe(Effect.map((digest) => Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("")));

/** Snapshots preserve their tenant-wide namespace; retained commands enforce service actor and labels. */
export const scopedSnapshotKey = (key: string) =>
  Effect.promise(() => crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(["key", key])))).pipe(
    Effect.map((digest) => Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("")),
  );

/** Internal child namespace, disjoint from caller-provided snapshot keys. */
export const scopedForkSnapshotKey = (parent: string) =>
  Effect.promise(() => crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(["fork-snapshot:v1", parent])))).pipe(
    Effect.map((digest) => Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("")),
  );
