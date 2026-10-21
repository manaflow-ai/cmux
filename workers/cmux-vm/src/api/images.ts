import { Schema } from "effect";

export const VmImageId = Schema.String.pipe(Schema.minLength(1), Schema.maxLength(63),
  Schema.pattern(/^[a-z][a-z0-9-]*$/u), Schema.filter((value) => value.trim() === value));
export const VmImageRevision = Schema.String.pipe(Schema.minLength(1), Schema.maxLength(64),
  Schema.pattern(/^[A-Za-z0-9][A-Za-z0-9._-]*$/u), Schema.filter((value) => value.trim() === value));

export const VmImageSelection = Schema.Struct({ id: VmImageId, revision: VmImageRevision }).annotations({
  identifier: "VmImageSelection",
  description: "An operator-approved service image at an exact revision. Mutually exclusive with snapshotId.",
  parseOptions: { onExcessProperty: "error" },
  message: () => ({ message: "Invalid VM image selection", override: true }),
});
export type VmImageSelection = typeof VmImageSelection.Type;

export const VmImage = Schema.Struct({ ...VmImageSelection.fields, displayName: Schema.String }).annotations({
  identifier: "VmImage",
  description: "Public image identity; provider snapshot references are never returned.",
});
export type VmImage = typeof VmImage.Type;

export class VmImageList extends Schema.Class<VmImageList>("VmImageList")({ items: Schema.Array(VmImage) }) {}
