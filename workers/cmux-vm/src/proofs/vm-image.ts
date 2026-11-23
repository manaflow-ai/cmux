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

/** Configured order (VM_BOOT_IMAGES): the first entry is the image in use, which the product smoke boots. */
export const visibleVmImages = <C>(caller: Named<C, Principal>) => Effect.gen(function* () {
  if (keyHasScope(caller, "vm:read") === null) return yield* Effect.fail(missingScope("vm:read"));
  const catalog = yield* VmImages;
  // The listing alone carries the inputs key; a creation receipt (publicImage) stays id, revision and name.
  return catalog.images.filter((image) => visible(caller.value, image))
    .map((image) => image.inputs_sha256 === undefined ? publicImage(image) : Object.freeze({ ...publicImage(image), inputs_sha256: image.inputs_sha256 }));
});

export interface VmImageAllowed<C> extends Proof<"VmImageAllowed", [C]> {}
interface Evidence {
  /** The snapshot a new create boots: the image's own, or its large one when `sizedFor` asked for exactly that size. */
  readonly snapshotId: UpstreamId;
  /** Which of the revision's snapshots `snapshotId` is. Both are the same image id and revision. */
  readonly variant: "base" | "large";
  /**
   * The revision's other snapshot, when it lists a large one. Only a retry reads it: a create journaled from this
   * snapshot (its retained source digest says so) keeps it, whatever a first attempt would boot now.
   */
  readonly other?: { readonly snapshotId: UpstreamId; readonly variant: "base" | "large" };
  readonly receipt: VmImage;
  readonly fingerprint: string;
}
/** The size axes of a create (upstream/client.ts SizeRequest). */
interface AskedSize { readonly vcpus?: number | undefined; readonly memoryMib?: number | undefined; readonly diskMib?: number | undefined }
const Allowed = defineProof("VmImageAllowed");
const evidence = new WeakMap<object, Evidence>();
export const vmImageEvidenceOf = <C>(proof: VmImageAllowed<C>): Evidence => {
  const value = evidence.get(proof);
  if (value === undefined) throw new Error("VmImageAllowed proof was not minted by src/proofs");
  return value;
};

/**
 * `sizedFor`: the size the create asks for, given only for a caller that may boot a large snapshot
 * (CMUX_VM_SIZED_IMAGE_SERVICE_IDS). The large snapshot boots when the ask names all three axes and each equals the
 * snapshot's: sizes only grow, so a larger snapshot than was asked would stay larger, and for a smaller ask the image's
 * own snapshot is resized as before. The fingerprint names the image's own snapshot either way: which snapshot of the
 * revision boots is not part of what the caller asked for (the size is, in the create's own fingerprint).
 */
export const vmImageAllowed = <C>(caller: Named<C, Principal>, input: VmImageSelection, sizedFor?: AskedSize) => Effect.gen(function* () {
  if (keyHasScope(caller, "vm:write") === null) return yield* Effect.fail(missingScope("vm:write"));
  const catalog = yield* VmImages;
  const image = catalog.images.find((item) => item.id === input.id && visible(caller.value, item));
  if (image === undefined) return yield* Effect.fail(new NotFound({ message: "VM image not found" }));
  if (image.revision !== input.revision) return yield* Effect.fail(conflict("VM image revision changed; reload the available images"));
  const digest = yield* Effect.promise(() => crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify([image.id, image.revision, image.snapshotId]))));
  const fingerprint = Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
  const proof: VmImageAllowed<C> = Object.freeze({ ...Allowed.prove(caller) });
  const base = { snapshotId: UpstreamId.make(image.snapshotId), variant: "base" as const };
  const large = image.large === undefined ? undefined : { snapshotId: UpstreamId.make(image.large.snapshotId), variant: "large" as const };
  const baked = image.large;
  const sized = baked !== undefined && sizedFor !== undefined
    && sizedFor.vcpus === baked.vcpus && sizedFor.memoryMib === baked.memoryMib && sizedFor.diskMib === baked.diskMib;
  const boots = sized && large !== undefined ? large : base;
  const other = boots === base ? large : base;
  evidence.set(proof, Object.freeze({ ...boots, ...(other === undefined ? {} : { other }), receipt: publicImage(image), fingerprint }));
  return proof;
});
