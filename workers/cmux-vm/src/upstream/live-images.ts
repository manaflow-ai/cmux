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
}).annotations({ parseOptions: { onExcessProperty: "error" } });
const Entries = Schema.Array(Entry).pipe(Schema.maxItems(32),
  Schema.filter((items) => new Set(items.map((item) => item.id)).size === items.length));
export interface ApprovedImage {
  readonly id: string; readonly revision: string; readonly displayName: string;
  readonly snapshotId: string; readonly services: ReadonlySet<string>;
}
export class VmImages extends Context.Tag("cmux-vm/VmImages")<VmImages, { readonly images: ReadonlyArray<ApprovedImage> }>() {}

export const parseVmImages = (raw: string | undefined): { readonly ok: boolean; readonly images: ReadonlyArray<ApprovedImage> } => {
  if (raw === undefined || raw.trim() === "") return { ok: true, images: [] };
  try {
    const json: unknown = JSON.parse(raw);
    const decoded = Schema.decodeUnknownOption(Entries)(json);
    if (Option.isNone(decoded)) return { ok: false, images: [] };
    return { ok: true, images: decoded.value.map((entry) => Object.freeze({ ...entry, services: new Set(entry.services) })) };
  } catch { return { ok: false, images: [] }; }
};

export const vmImagesLayer = (raw: string | undefined): Layer.Layer<VmImages> => {
  const parsed = parseVmImages(raw);
  if (!parsed.ok) console.error("cmux-vm VM_BOOT_IMAGES is invalid; approved images are disabled");
  return Layer.succeed(VmImages, { images: parsed.images });
};
