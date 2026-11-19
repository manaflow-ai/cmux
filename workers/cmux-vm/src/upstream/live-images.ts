/** Operator image references stay behind the same import boundary as provider credentials. */
import { Context, Layer, Option, Schema } from "effect";
import { VmImageId, VmImageRevision } from "../api/images.ts";

const SnapshotRef = Schema.String.pipe(Schema.minLength(1), Schema.maxLength(256), Schema.filter((value) =>
  value !== "." && value !== ".." && !/[^\x21-\x7e]/u.test(value)));
const Entry = Schema.Struct({
  id: VmImageId, revision: VmImageRevision,
  displayName: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(100), Schema.filter((value) =>
    Array.from(value).every((character) => character.charCodeAt(0) >= 32 && character.charCodeAt(0) !== 127))),
  snapshotId: SnapshotRef,
  services: Schema.Array(Schema.String.pipe(Schema.pattern(/^[a-z][a-z0-9-]{0,39}$/u), Schema.filter((value) => value.trim() === value)))
    .pipe(Schema.minItems(1), Schema.maxItems(32)),
  // Optional and advisory: a malformed value is dropped (below) rather than disabling every image.
  inputs_sha256: Schema.optional(Schema.Unknown),
  // Optional too, and dropped when malformed for the same reason: the image then boots its own snapshot and grows.
  large: Schema.optional(Schema.Unknown),
}).annotations({ parseOptions: { onExcessProperty: "error" } });
const Entries = Schema.Array(Entry).pipe(Schema.maxItems(32),
  Schema.filter((items) => new Set(items.map((item) => item.id)).size === items.length));
/**
 * The same image baked at another size: its own provider snapshot and the size a VM made from it boots at. A create
 * that asks for exactly this size boots it and needs no resize (src/upstream/live-create.ts).
 */
export interface ImageVariant {
  readonly name: string; readonly snapshotId: string;
  readonly vcpus: number; readonly memoryMib: number; readonly diskMib: number;
}
const Variant = Schema.Struct({
  snapshotId: SnapshotRef,
  vcpus: Schema.Number.pipe(Schema.int(), Schema.between(1, 64)),
  memoryMib: Schema.Number.pipe(Schema.int(), Schema.between(1, 1_048_576)),
  diskMib: Schema.Number.pipe(Schema.int(), Schema.between(1, 4_194_304)),
}).annotations({ parseOptions: { onExcessProperty: "error" } });
/** The entry's variants by the field that lists each (`large`: the default Cloud chat start size). One that shares the image's own snapshot is no variant. */
const variantsOf = (entry: { readonly snapshotId: string }, listed: Readonly<Record<string, unknown>>): ReadonlyArray<ImageVariant> =>
  Object.entries(listed).flatMap(([name, raw]) => Option.match(Schema.decodeUnknownOption(Variant)(raw), {
    onNone: () => [],
    onSome: (variant) => variant.snapshotId === entry.snapshotId ? [] : [Object.freeze({ name, ...variant })],
  }));
export interface ApprovedImage {
  readonly id: string; readonly revision: string; readonly displayName: string;
  readonly snapshotId: string; readonly services: ReadonlySet<string>;
  /** The image's inputs key (images/cmux-vm/auto-roll.ts), 64 lowercase hex, when the entry records one. */
  readonly inputs_sha256?: string;
  /** Size variants of this image; empty for an entry that lists none. */
  readonly variants: ReadonlyArray<ImageVariant>;
}
export class VmImages extends Context.Tag("cmux-vm/VmImages")<VmImages, { readonly images: ReadonlyArray<ApprovedImage> }>() {}

export const parseVmImages = (raw: string | undefined): { readonly ok: boolean; readonly images: ReadonlyArray<ApprovedImage> } => {
  if (raw === undefined || raw.trim() === "") return { ok: true, images: [] };
  try {
    const json: unknown = JSON.parse(raw);
    const decoded = Schema.decodeUnknownOption(Entries)(json);
    if (Option.isNone(decoded)) return { ok: false, images: [] };
    return { ok: true, images: decoded.value.map(({ inputs_sha256, large, ...entry }) => Object.freeze({
      ...entry, services: new Set(entry.services), variants: variantsOf(entry, large === undefined ? {} : { large }),
      ...(typeof inputs_sha256 === "string" && /^[0-9a-f]{64}$/u.test(inputs_sha256) ? { inputs_sha256 } : {}),
    })) };
  } catch { return { ok: false, images: [] }; }
};

export const vmImagesLayer = (raw: string | undefined): Layer.Layer<VmImages> => {
  const parsed = parseVmImages(raw);
  if (!parsed.ok) console.error("cmux-vm VM_BOOT_IMAGES is invalid; approved images are disabled");
  return Layer.succeed(VmImages, { images: parsed.images });
};
