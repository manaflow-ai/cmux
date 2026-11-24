/** Operator image references stay behind the same import boundary as provider credentials. */
import { Context, Layer, Option, Schema } from "effect";
import { VmImageId, VmImageRevision } from "../api/images.ts";

const Entry = Schema.Struct({
  id: VmImageId, revision: VmImageRevision,
  displayName: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(100), Schema.filter((value) =>
    Array.from(value).every((character) => character.charCodeAt(0) >= 32 && character.charCodeAt(0) !== 127))),
  snapshotId: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(256), Schema.filter((value) =>
    value !== "." && value !== ".." && !/[^\x21-\x7e]/u.test(value))),
  services: Schema.Array(Schema.String.pipe(Schema.pattern(/^[a-z][a-z0-9-]{0,39}$/u), Schema.filter((value) => value.trim() === value)))
    .pipe(Schema.minItems(1), Schema.maxItems(32)),
  // Optional and advisory: a malformed value is dropped (below) rather than disabling every image.
  inputs_sha256: Schema.optional(Schema.Unknown),
  // Optional: a malformed value is dropped (below), and the image then boots its own snapshot and is resized.
  large: Schema.optional(Schema.Unknown),
}).annotations({ parseOptions: { onExcessProperty: "error" } });
const snapshotIdOk = (value: string) => value.length >= 1 && value.length <= 256 && value !== "." && value !== ".." && !/[^\x21-\x7e]/u.test(value);
/** The sizes a create may ask for (src/api.ts RequestedResources): a large snapshot at any other size is never asked for. */
const Large = Schema.Struct({
  snapshotId: Schema.String.pipe(Schema.filter(snapshotIdOk)),
  vcpus: Schema.Int.pipe(Schema.between(2, 32)),
  memoryMib: Schema.Int.pipe(Schema.between(4096, 65536)),
  diskMib: Schema.Int.pipe(Schema.between(16384, 131072)),
}).annotations({ parseOptions: { onExcessProperty: "error" } });
/**
 * A second snapshot of the same bake, taken after its builder was grown to this size (web/scripts/cmux-vm-image/
 * large-image.ts): the same tree as the entry's own snapshot, so the same image id and revision. A VM created from it
 * boots at this size, and one asked for exactly this size needs no resize after its create.
 */
export interface LargeImage { readonly snapshotId: string; readonly vcpus: number; readonly memoryMib: number; readonly diskMib: number }
const Entries = Schema.Array(Entry).pipe(Schema.maxItems(32),
  Schema.filter((items) => new Set(items.map((item) => item.id)).size === items.length));
export interface ApprovedImage {
  readonly id: string; readonly revision: string; readonly displayName: string;
  readonly snapshotId: string; readonly services: ReadonlySet<string>;
  /** The image's inputs key (images/cmux-vm/auto-roll.ts), 64 lowercase hex, when the entry records one. */
  readonly inputs_sha256?: string;
  /** This revision's large snapshot, when the entry records a well-formed one that is not the entry's own snapshot. */
  readonly large?: LargeImage;
}
export class VmImages extends Context.Tag("cmux-vm/VmImages")<VmImages, { readonly images: ReadonlyArray<ApprovedImage> }>() {}

export const parseVmImages = (raw: string | undefined): { readonly ok: boolean; readonly images: ReadonlyArray<ApprovedImage> } => {
  if (raw === undefined || raw.trim() === "") return { ok: true, images: [] };
  try {
    const json: unknown = JSON.parse(raw);
    const decoded = Schema.decodeUnknownOption(Entries)(json);
    if (Option.isNone(decoded)) return { ok: false, images: [] };
    return { ok: true, images: decoded.value.map(({ inputs_sha256, large, ...entry }) => {
      const sized = Schema.decodeUnknownOption(Large)(large);
      return Object.freeze({
        ...entry, services: new Set(entry.services),
        ...(typeof inputs_sha256 === "string" && /^[0-9a-f]{64}$/u.test(inputs_sha256) ? { inputs_sha256 } : {}),
        ...(Option.isSome(sized) && sized.value.snapshotId !== entry.snapshotId ? { large: Object.freeze({ ...sized.value }) } : {}),
      });
    }) };
  } catch { return { ok: false, images: [] }; }
};

export const vmImagesLayer = (raw: string | undefined): Layer.Layer<VmImages> => {
  const parsed = parseVmImages(raw);
  if (!parsed.ok) console.error("cmux-vm VM_BOOT_IMAGES is invalid; approved images are disabled");
  return Layer.succeed(VmImages, { images: parsed.images });
};
