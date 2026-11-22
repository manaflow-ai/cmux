/**
 * Browser helpers for the avatar editor, ported from Hexclave's
 * `profile-image-editor`: read a file, crop a region to a JPEG data URL, and
 * compress it to roughly 100 KB.
 */
export type PixelCrop = { x: number; y: number; width: number; height: number };

/** Target size passed to browser-image-compression (0.1 MB, as Hexclave). */
export const AVATAR_MAX_SIZE_MB = 0.1;

export function isImageFile(file: Pick<File, "type">): boolean {
  return file.type.startsWith("image/");
}

export function readFileAsDataUrl(file: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      if (typeof reader.result === "string") resolve(reader.result);
      else reject(new Error("Unexpected file reader result"));
    };
    reader.onerror = () => reject(reader.error ?? new Error("File read failed"));
    reader.readAsDataURL(file);
  });
}

export function loadImage(url: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const image = new Image();
    image.addEventListener("load", () => resolve(image));
    image.addEventListener("error", () => reject(new Error("Image failed to load")));
    image.setAttribute("crossOrigin", "anonymous");
    image.src = url;
  });
}

/** Clamp a crop to non-negative origin and at least 1px in each dimension. */
export function safeCrop(crop: PixelCrop): PixelCrop {
  return {
    x: Math.max(0, crop.x),
    y: Math.max(0, crop.y),
    width: Math.max(1, crop.width),
    height: Math.max(1, crop.height),
  };
}

export async function cropToJpegDataUrl(
  imageSrc: string,
  crop: PixelCrop,
): Promise<string | null> {
  const image = await loadImage(imageSrc);
  const canvas = document.createElement("canvas");
  const context = canvas.getContext("2d");
  if (!context) return null;
  const area = safeCrop(crop);
  canvas.width = area.width;
  canvas.height = area.height;
  context.drawImage(image, area.x, area.y, area.width, area.height, 0, 0, area.width, area.height);
  return canvas.toDataURL("image/jpeg");
}

export async function compressJpegDataUrl(dataUrl: string): Promise<string> {
  const { default: imageCompression } = await import("browser-image-compression");
  const file = await imageCompression.getFilefromDataUrl(dataUrl, "profile-image");
  const compressed = await imageCompression(file, {
    maxSizeMB: AVATAR_MAX_SIZE_MB,
    fileType: "image/jpeg",
  });
  return imageCompression.getDataUrlFromFile(compressed);
}
