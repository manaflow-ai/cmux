/** Trusted: only a configured service acting for this tenant may select an operator image. */
import { defineProof, type Named, type Proof } from "@gdp-ts/core";
import { Effect } from "effect";
import type { VmImage, VmImageSelection } from "../api/images.ts";
import type { Principal } from "../domain/principal.ts";
import { conflict, missingScope, NotFound } from "../errors.ts";
import { UpstreamId } from "../lib/ids.ts";
import { VmImages, type ApprovedImage } from "../upstream/live-images.ts";
import { keyHasScope } from "./key-has-scope.ts";
export type { VmImages } from "../upstream/live-images.ts";

const visible = (principal: Principal, image: ApprovedImage) =>
  principal.actor.kind === "service" && image.services.has(principal.actor.serviceId);
const publicImage = (image: ApprovedImage): VmImage => Object.freeze({ id: image.id, revision: image.revision, displayName: image.displayName });

export const visibleVmImages = <C>(caller: Named<C, Principal>) => Effect.gen(function* () {
  if (keyHasScope(caller, "vm:read") === null) return yield* Effect.fail(missingScope("vm:read"));
  const catalog = yield* VmImages;
  return catalog.images.filter((image) => visible(caller.value, image)).map(publicImage).sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
});

export interface VmImageAllowed<C> extends Proof<"VmImageAllowed", [C]> {}
interface Evidence { readonly snapshotId: UpstreamId; readonly receipt: VmImage; readonly fingerprint: string }
const Allowed = defineProof("VmImageAllowed");
const evidence = new WeakMap<object, Evidence>();
export const vmImageEvidenceOf = <C>(proof: VmImageAllowed<C>): Evidence => {
  const value = evidence.get(proof);
  if (value === undefined) throw new Error("VmImageAllowed proof was not minted by src/proofs");
  return value;
};

export const vmImageAllowed = <C>(caller: Named<C, Principal>, input: VmImageSelection) => Effect.gen(function* () {
  if (keyHasScope(caller, "vm:write") === null) return yield* Effect.fail(missingScope("vm:write"));
  const catalog = yield* VmImages;
  const image = catalog.images.find((item) => item.id === input.id && visible(caller.value, item));
  if (image === undefined) return yield* Effect.fail(new NotFound({ message: "VM image not found" }));
  if (image.revision !== input.revision) return yield* Effect.fail(conflict("VM image revision changed; reload the available images"));
  const digest = yield* Effect.promise(() => crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify([image.id, image.revision, image.snapshotId]))));
  const fingerprint = Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
  const proof: VmImageAllowed<C> = Object.freeze({ ...Allowed.prove(caller) });
  evidence.set(proof, Object.freeze({ snapshotId: UpstreamId.make(image.snapshotId), receipt: publicImage(image), fingerprint }));
  return proof;
});
