/** Public recovery metadata for server-issued keys only. Client-supplied keys never enter this record. */
import { Schema } from "effect";
import { VmCreationKey, VmId } from "../lib/ids.ts";
import { actorRef, type Principal } from "./principal.ts";

export const GeneratedCreation = Schema.Struct({
  key: VmCreationKey,
  cursor: Schema.String.pipe(Schema.pattern(/^[a-f0-9]{64}$/)),
  scope: Schema.String,
  createdBy: Schema.String,
  createdAt: Schema.String,
  displayName: Schema.NullOr(Schema.String),
  labels: Schema.Record({ key: Schema.String, value: Schema.String }),
  operation: Schema.Literal("create", "fork"),
  sourceId: Schema.optional(VmId),
});
export type GeneratedCreation = typeof GeneratedCreation.Type;
export const GeneratedCreationPage = Schema.Struct({ items: Schema.Array(GeneratedCreation), nextCursor: Schema.NullOr(Schema.String),
  pendingIndex: Schema.optional(Schema.Literal("ready", "building", "unavailable")) });
export type GeneratedCreationPage = typeof GeneratedCreationPage.Type;
export const creationDiscoveryScope = (principal: Principal) => principal.actor.kind === "service" ? actorRef(principal.actor) : "tenant";
