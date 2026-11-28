// A favicon's ink, for the New Tab rows (RowGlyph). A one-colour favicon made for a light page (the GitHub
// mark, the Vercel triangle) vanished on the dark rows (Lucas 2026-11-26), and a white one does the same on
// light rows. The sidebar measures the same thing (SidebarFaviconInk.swift, its `adaptive` style); this is
// that rule with the same constants, plus tiles. The theme picks the drawing in CSS (screen.css `data-ink`): a
// dark mark draws in the label colour on the dark theme, a light mark on the light theme; a one-ink tile with a
// knockout (Vercel's black disc with a white triangle) draws inverted there, since a tint would fill the
// knockout; any other favicon draws as is.
import { useEffect, useState } from "react";

/// A one-colour favicon's ink: "dark" or "light" (WCAG relative luminance below or above mid grey); a "-tile"
/// has a knockout in it (an off-ink shape: Vercel's white triangle in its black disc).
export type FaviconInk = "dark" | "light" | "dark-tile" | "light-tile";

/// Side of the bitmap a favicon is measured at: enough for its shape, cheap for a 256 px icon.
const SAMPLE_SIDE = 32;
/// Alpha (of 255) a pixel needs to count as ink, so the antialiased fringe does not count.
const OPAQUE = 128;
/// Chroma (max minus min channel, 0...1) above which a pixel counts as coloured.
const COLOURED_CHROMA = 0.18;
/// Share of coloured ink pixels a one-colour favicon may have (a stray tinted antialias pixel).
const COLOURED_SHARE = 0.06;
/// How far (relative luminance) an ink pixel may sit from the median and still be the same ink.
const LUMINANCE_SPREAD = 0.12;
/// Share of ink pixels that must be within LUMINANCE_SPREAD of the median: "mostly one luminance".
const ONE_INK_SHARE = 0.85;
/// Share of opaque pixels off the ink (a white or grey shape in a black tile) that makes a favicon a tile: a
/// knockout that a tint would fill and lose.
const KNOCKOUT_SHARE = 0.02;
/// Relative luminance of mid grey: an ink below it disappears on a dark ground, above it on a light one.
const MID_GREY = 0.18;
/// Favicons measured: the rows' few at a time, bounded so a long session cannot grow it.
const CACHE_LIMIT = 256;

/// WCAG relative luminance of an sRGB colour (channels 0...1).
export function relativeLuminance(r: number, g: number, b: number): number {
  const linear = (c: number) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
  return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b);
}

/// The ink of RGBA `pixels` (straight alpha, as `getImageData` gives them): undefined for a colourful
/// favicon, one of several greys, or one with no opaque pixel.
export function inkOf(pixels: ArrayLike<number>): FaviconInk | undefined {
  const luminances: number[] = [];
  let coloured = 0;
  for (let index = 0; index + 3 < pixels.length; index += 4) {
    if (pixels[index + 3]! < OPAQUE) continue;
    const r = pixels[index]! / 255;
    const g = pixels[index + 1]! / 255;
    const b = pixels[index + 2]! / 255;
    if (Math.max(r, g, b) - Math.min(r, g, b) > COLOURED_CHROMA) coloured += 1;
    luminances.push(relativeLuminance(r, g, b));
  }
  if (!luminances.length) return undefined;
  const count = luminances.length;
  const median = [...luminances].sort((a, b) => a - b)[Math.floor(count / 2)]!;
  const oneInk = luminances.filter((value) => Math.abs(value - median) <= LUMINANCE_SPREAD).length / count;
  if (coloured / count > COLOURED_SHARE || oneInk < ONE_INK_SHARE) return undefined;
  const ink = luminances.filter((value) => Math.abs(value - median) <= LUMINANCE_SPREAD);
  const mean = ink.reduce((sum, value) => sum + value, 0) / ink.length;
  const knockout = 1 - ink.length / count;
  const tone = mean < MID_GREY ? "dark" : "light";
  return knockout >= KNOCKOUT_SHARE ? `${tone}-tile` : tone;
}

/// Measured favicons, by their data URL: null for "draw as is".
const measured = new Map<string, FaviconInk | null>();
const measuring = new Map<string, Promise<FaviconInk | null>>();

function remember(src: string, ink: FaviconInk | null) {
  if (measured.size >= CACHE_LIMIT) measured.delete(measured.keys().next().value!);
  measured.set(src, ink);
}

function measure(src: string): Promise<FaviconInk | null> {
  const running = measuring.get(src);
  if (running) return running;
  const done = new Promise<FaviconInk | null>((resolve) => {
    const image = new Image();
    image.onload = () => {
      try {
        const canvas = document.createElement("canvas");
        canvas.width = SAMPLE_SIDE;
        canvas.height = SAMPLE_SIDE;
        const context = canvas.getContext("2d", { willReadFrequently: true });
        if (!context) return resolve(null);
        context.drawImage(image, 0, 0, SAMPLE_SIDE, SAMPLE_SIDE);
        resolve(inkOf(context.getImageData(0, 0, SAMPLE_SIDE, SAMPLE_SIDE).data) ?? null);
      } catch {
        resolve(null);
      }
    };
    image.onerror = () => resolve(null);
    image.src = src;
  }).then((ink) => {
    measuring.delete(src);
    remember(src, ink);
    return ink;
  });
  measuring.set(src, done);
  return done;
}

/// The ink of the favicon `src` (a `data:image/` URL from the host), measured once off the render: undefined
/// until it is measured, and for a favicon that draws as is.
export function useFaviconInk(src: string | undefined): FaviconInk | undefined {
  const known = src ? measured.get(src) : undefined;
  const [ink, setInk] = useState<{ src: string; ink: FaviconInk | null } | undefined>(undefined);
  useEffect(() => {
    if (!src) return;
    // Measured by another row since this one rendered: publish it, or this row keeps drawing as fetched.
    if (measured.has(src)) return setInk({ src, ink: measured.get(src)! });
    let live = true;
    void measure(src).then((value) => {
      if (live) setInk({ src, ink: value });
    });
    return () => {
      live = false;
    };
  }, [src]);
  if (!src) return undefined;
  if (known !== undefined) return known ?? undefined;
  return ink?.src === src ? (ink.ink ?? undefined) : undefined;
}
