// The poster as a PNG: the preview's own SVG element, serialized and drawn to a canvas at twice its
// size. What the person saw in the preview is exactly what is copied or saved. One draw per open
// or per change of what the poster shows (the share link, the look), never per token.
import { POSTER_HEIGHT, POSTER_WIDTH } from "./posterModel";

/// Pixels per poster unit: 2400 by 1600, sharp on a Retina screen and in a post.
const SCALE = 2;

/// The SVG's markup as a `data:` URL an image can load.
export function svgDataUrl(svg: SVGSVGElement): string {
  const markup = new XMLSerializer().serializeToString(svg);
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(markup)}`;
}

/// `svg` drawn to a PNG `data:` URL. Fails, rather than giving a blank, when the image cannot load
/// or the canvas cannot draw.
export function posterPng(svg: SVGSVGElement): Promise<string> {
  const src = svgDataUrl(svg);
  return new Promise((resolve, reject) => {
    const image = new Image();
    image.onload = () => {
      try {
        const canvas = document.createElement("canvas");
        canvas.width = POSTER_WIDTH * SCALE;
        canvas.height = POSTER_HEIGHT * SCALE;
        const context = canvas.getContext("2d");
        if (!context) throw new Error("poster.canvas");
        context.drawImage(image, 0, 0, canvas.width, canvas.height);
        resolve(canvas.toDataURL("image/png"));
      } catch (error) {
        reject(error instanceof Error ? error : new Error("poster.draw"));
      }
    };
    image.onerror = () => reject(new Error("poster.decode"));
    image.src = src;
  });
}

/// A PNG `data:` URL as a Blob, for the page's own clipboard and download (no native host).
export function pngBlob(dataUrl: string): Blob {
  const bytes = atob(dataUrl.slice(dataUrl.indexOf(",") + 1));
  const buffer = new Uint8Array(bytes.length);
  for (let index = 0; index < bytes.length; index++) buffer[index] = bytes.charCodeAt(index);
  return new Blob([buffer], { type: "image/png" });
}
