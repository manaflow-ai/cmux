/// An attachment thumbnail is a small `object-fit: cover` tile, so a picture of another shape is cut to
/// fit it. The cut keeps the picture's start (composerAttachments.css `object-position: left top`): a
/// wide screenshot of text shows its first words, never a slice from its middle cut on both sides
/// (Leo, 2026-11-27: "did we fix this yet", on a tile reading "or a script: lane-deploy").
///
/// `cropAxis` says which side the cover cuts, so that end fades (`data-crop`) as text ends in an
/// ellipsis: the tile reads as continuing past its edge, not as clipped.

/// How far the picture's shape may differ from its tile's before the cut counts (rounding, a pixel).
const SLACK = 1.04;

export type CropAxis = "x" | "y" | undefined;

/// "x" when the picture is wider than its tile (its right side is cut), "y" when taller (its bottom),
/// undefined when it fits or either size is unknown.
export function cropAxis(natural: { width: number; height: number }, box: { width: number; height: number }): CropAxis {
  if (!(natural.width > 0 && natural.height > 0 && box.width > 0 && box.height > 0)) return undefined;
  const picture = natural.width / natural.height;
  const tile = box.width / box.height;
  if (picture > tile * SLACK) return "x";
  if (picture * SLACK < tile) return "y";
  return undefined;
}

/// Marks a decoded thumbnail with the side its tile cuts, for its fade (composerAttachments.css).
export function markCrop(image: HTMLImageElement): void {
  const axis = cropAxis(
    { width: image.naturalWidth, height: image.naturalHeight },
    { width: image.clientWidth, height: image.clientHeight },
  );
  if (axis) image.dataset.crop = axis;
  else delete image.dataset.crop;
}
