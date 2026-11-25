/// What an attached image is called on hover and in the viewer (Leo, 2026-10-20: every pasted
/// image read "image.png"). WebKit names pasted image data "image.png", so that name says nothing:
/// a pasted image reads "Screenshot · 2458×2324" at its natural size instead, or
/// "<source> screenshot · …" when the app it came from is known. A real file name (a dropped file,
/// a capture named for when it was taken) shows as itself.
import type { Translate } from "./i18n";

export type ImageFacts = {
  /** The attachment's file name, if any. */
  name?: string;
  /** The app the image was copied from, when the host knows it. */
  source?: string;
  /** The image's natural size, once it has loaded. */
  width?: number;
  height?: number;
};

/// Names a clipboard or the pane gives an image that has no name of its own: WebKit's
/// "image.png" for pasted data, macOS's "Pasted Graphic", "Untitled", the composer's "file", and
/// the "image-2" a Retry or Edit gives a sent image acpmux kept no name for.
const PLACEHOLDER_NAME = /^(?:image|pasted ?(?:image|graphic)|untitled|file|blob)(?:[ _-]?\d+)?(?:\.[a-z0-9]{2,5})?$/i;

export function isPlaceholderImageName(name: string | undefined): boolean {
  const trimmed = name?.trim();
  return !trimmed || PLACEHOLDER_NAME.test(trimmed);
}

export function imageLabel(t: Translate, { name, source, width, height }: ImageFacts): string {
  if (!isPlaceholderImageName(name)) return name!.trim();
  const label = source?.trim() ? t("image.screenshotFrom", { source: source.trim() }) : t("image.screenshot");
  return width && height ? t("image.withSize", { label, width, height }) : label;
}

/// A list's name for each image in it, in the order given (Leo, 2026-11-05, on Session Info's
/// Sources reading "image.png" five times: "instead of, like screenshot number one, two, three,
/// four"): an image with no name of its own is "Screenshot 1", "Screenshot 2", ... (or
/// "<source> screenshot 3") counting only those, so two pasted images never read alike; a real
/// file name shows as itself and takes no number.
export function numberedImageLabels(t: Translate, images: readonly Pick<ImageFacts, "name" | "source">[]): string[] {
  let number = 0;
  return images.map(({ name, source }) => {
    if (!isPlaceholderImageName(name)) return name!.trim();
    number += 1;
    return source?.trim()
      ? t("image.screenshotFromNumbered", { source: source.trim(), number })
      : t("image.screenshotNumbered", { number });
  });
}
