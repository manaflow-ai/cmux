// The chat's images, kept so a re-render never blinks or reshapes one (Leo, 2026-10-21: chat
// images kept blinking and turned from square to rectangle as they loaded).
//
// - Each image's box is known before it decodes: a data URL's size is read from its header (PNG,
//   GIF, WebP, JPEG), and any image the pane has drawn keeps its measured size, so its frame is
//   reserved at its own shape from the first frame and never snaps.
// - A sent image (acpmux names it by the SHA-256 of its bytes) is read and decoded once, then
//   served from here by the same entry, so a re-rendered or remounted bubble draws it at once with
//   the same `src` and no placeholder in between. The pane primes the entry when it sends the
//   image, so its bubble never waits on a read at all.
// - An image fades in the first time it draws only: a row that remounts (the virtual transcript
//   scrolling it back, a streaming turn) shows it as it was.

import { useEffect, useReducer, useRef, useState } from "react";
import type { ComposerAttachment } from "../attachments";

export type ImageSize = { width: number; height: number };
/// A sent image ready to draw: its data URL, its natural size when known, and whether the engine
/// decoded it ahead. The element that decoded it is not held: up to 128 decoded screenshots would
/// pin gigabytes, and the engine's own image cache serves the same src string again.
export type ImageEntry = { src: string; size?: ImageSize; decoded?: boolean };

/// Sent images by acpmux id, most recently drawn last, within a count and a total data URL length.
const MAX_ENTRIES = 128;
const MAX_CHARS = 48_000_000;
const entries = new Map<string, ImageEntry>();
let entryChars = 0;
/// Reads in flight, so two bubbles showing one image ask acpmux once.
const reading = new Map<string, Promise<ImageEntry | undefined>>();
/// Measured sizes by acpmux id or source fingerprint; a size is a few bytes, so many are kept.
const MAX_SIZES = 4096;
const sizes = new Map<string, ImageSize>();
/// Images that have drawn once (by fingerprint): they never fade in again.
const drawn = new Set<string>();
/// Data URLs whose header names no size (an SVG, a format it does not read), so it is read once.
const headless = new Set<string>();
/// Bubbles showing a sent image not kept yet, by acpmux id: each is told the moment the image is
/// kept, by whoever keeps it (the pane priming the image it sent, another bubble's read), so none
/// waits on its own read (Leo, 2026-10-21: a pasted image showed as an empty box; acpmux's echo
/// named it before the pane had primed it, and acpmux's read scans the whole chat log).
const waiting = new Map<string, Set<(entry: ImageEntry) => void>>();

/// Calls `tell` when the sent image `id` is kept; the returned function stops it.
export function watchSentImage(id: string, tell: (entry: ImageEntry) => void): () => void {
  let watchers = waiting.get(id);
  if (!watchers) waiting.set(id, (watchers = new Set()));
  watchers.add(tell);
  return () => {
    watchers.delete(tell);
    if (watchers.size === 0 && waiting.get(id) === watchers) waiting.delete(id);
  };
}

/// A short key for an image source: a data URL can be megabytes, so a key never holds the source
/// itself. Its length, its header and tail, and a sample through its middle.
/// The key holds only numbers: a slice of a data URL can keep the whole URL alive in V8.
export function sourceKey(src: string): string {
  if (src.length <= 256) return src;
  const step = Math.max(1, Math.floor(src.length / 2048));
  // Two FNV-1a hashes over the header, the tail and a sample through the middle.
  let first = 0x811c9dc5;
  let second = 0x01000193;
  const mix = (at: number) => {
    const char = src.charCodeAt(at);
    first = Math.imul(first ^ char, 0x01000193);
    second = Math.imul(second ^ char, 0x5bd1e995) ^ (second >>> 15);
  };
  for (let at = 0; at < 128; at++) mix(at);
  for (let at = src.length - 128; at < src.length; at++) mix(at);
  for (let at = 0; at < src.length; at += step) mix(at);
  return `${src.length}:${(first >>> 0).toString(36)}:${(second >>> 0).toString(36)}`;
}

function remember(key: string, size: ImageSize) {
  sizes.delete(key);
  sizes.set(key, size);
  if (sizes.size > MAX_SIZES) sizes.delete(sizes.keys().next().value!);
}

/// Records an image's natural size, by acpmux id or by its source.
export function rememberImageSize(key: { id: string } | { src: string }, size: ImageSize): void {
  if (!(size.width > 0) || !(size.height > 0)) return;
  remember("id" in key ? `id:${key.id}` : `src:${sourceKey(key.src)}`, size);
}

/// An image's natural size before it decodes: the size it drew at before, else its data URL's
/// header (read once per image).
export function knownImageSize(src: string): ImageSize | undefined {
  const key = sourceKey(src);
  const known = sizes.get(`src:${key}`);
  if (known || headless.has(key)) return known;
  const header = dataUrlImageSize(src);
  if (header) remember(`src:${key}`, header);
  else {
    headless.add(key);
    if (headless.size > MAX_SIZES) headless.delete(headless.values().next().value!);
  }
  return header;
}

/// The size a sent image `id` drew at, or that the pane read when it sent it.
export function knownSentImageSize(id: string): ImageSize | undefined {
  return sizes.get(`id:${id}`) ?? entries.get(id)?.size;
}

/// Whether `src` has drawn in this pane before (it then draws without the fade-in).
export function hasDrawn(src: string): boolean {
  return drawn.has(sourceKey(src));
}

export function markDrawn(src: string, size?: ImageSize): void {
  const key = sourceKey(src);
  drawn.add(key);
  if (drawn.size > MAX_SIZES) drawn.delete(drawn.values().next().value!);
  if (size) rememberImageSize({ src }, size);
}

/// The sent image `id` when it is ready to draw: the same entry for as long as it is kept.
export function sentImageEntry(id: string): ImageEntry | undefined {
  const entry = entries.get(id);
  if (!entry) return undefined;
  entries.delete(id);
  entries.set(id, entry);
  return entry;
}

function keep(id: string, entry: ImageEntry): ImageEntry {
  const before = entries.get(id);
  if (before) {
    entries.delete(id);
    entryChars -= before.src.length;
  }
  entries.set(id, entry);
  entryChars += entry.src.length;
  // The newest image always stays, even one longer than the whole budget.
  while (entries.size > 1 && (entries.size > MAX_ENTRIES || entryChars > MAX_CHARS)) {
    const [oldest, value] = entries.entries().next().value!;
    entries.delete(oldest);
    entryChars -= value.src.length;
  }
  if (entry.size) rememberImageSize({ id }, entry.size);
  for (const tell of waiting.get(id) ?? []) tell(entry);
  return entry;
}

/// Decodes `src` off screen, so the <img> that shows it paints in its first frame, and measures it.
/// Undefined size where the engine cannot decode ahead (the <img> then measures it when it loads).
export async function decodeImage(src: string): Promise<{ size?: ImageSize; decoded?: boolean }> {
  const header = dataUrlImageSize(src);
  if (typeof Image !== "function") return { size: header };
  const image = new Image();
  image.decoding = "async";
  image.src = src;
  if (typeof image.decode !== "function") return { size: header };
  try {
    await image.decode();
  } catch {
    return { size: header };
  }
  const size =
    image.naturalWidth && image.naturalHeight ? { width: image.naturalWidth, height: image.naturalHeight } : header;
  return { size, decoded: true };
}

/// The sent image `id`, read with `read` (acpmux's `_acpmux/attachment`) and decoded once; every
/// caller gets the same entry. Undefined when acpmux has none; a failed read is not kept.
export function loadSentImage(
  id: string,
  read: (id: string) => Promise<string | undefined>,
): Promise<ImageEntry | undefined> {
  const known = sentImageEntry(id);
  if (known) return Promise.resolve(known);
  const inFlight = reading.get(id);
  if (inFlight) return inFlight;
  const load = (async () => {
    try {
      const src = await read(id);
      if (!src) return undefined;
      const raced = entries.get(id);
      if (raced) return raced;
      const { size, decoded } = await decodeImage(src);
      return entries.get(id) ?? keep(id, { src, size: size ?? knownSentImageSize(id), ...(decoded && { decoded }) });
    } finally {
      reading.delete(id);
    }
  })();
  reading.set(id, load);
  return load;
}

/// The pane is the producer of an image it sends: it keeps each one under the id acpmux will name
/// it by (the SHA-256 of its bytes, hub/prompt_images.rs), with its size, so the sent bubble draws
/// it at its own shape in the frame acpmux's echo arrives, without reading it back.
export async function primeSentImages(attachments: readonly ComposerAttachment[]): Promise<void> {
  const digest = globalThis.crypto?.subtle?.digest?.bind(globalThis.crypto.subtle);
  if (!digest) return;
  await Promise.all(
    attachments.map(async (attachment) => {
      if (attachment.kind !== "image" || !attachment.data) return;
      try {
        const text = atob(attachment.data);
        const bytes = new Uint8Array(text.length);
        for (let index = 0; index < text.length; index++) bytes[index] = text.charCodeAt(index);
        const hash = new Uint8Array(await digest("SHA-256", bytes));
        const id = Array.from(hash, (byte) => byte.toString(16).padStart(2, "0")).join("");
        if (entries.has(id)) return;
        const src = `data:${attachment.mimeType};base64,${attachment.data}`;
        const { size, decoded } = await decodeImage(src);
        if (!entries.has(id)) keep(id, { src, ...(size && { size }), ...(decoded && { decoded }) });
      } catch {
        // Not base64 or not an image: the bubble reads it from acpmux as before.
      }
    }),
  );
}

/// What an image source is: a data URL the page already has (a reply's image), or a sent image
/// acpmux names by `id` and `read` reads (TurnActions.promptImage).
export type StableImageSource = { src: string } | { id: string; read?: (id: string) => Promise<string | undefined> };

export type StableImage = {
  /// The source to draw, the same string for one image on every render; undefined while it is read.
  src?: string;
  /// The image's natural size when known (metadata, a previous draw, its header): reserve its
  /// frame from it (`width`/`height` attributes or `aspect-ratio`) before it decodes.
  width?: number;
  height?: number;
  /// "loading" while a sent image is read, "missing" when acpmux has none to read.
  status: "loading" | "ready" | "missing";
  /// The first time this image draws in the pane: fade it in then only, never on a remount.
  fresh: boolean;
  /// Decoded ahead or drawn before: draw it with `decoding="sync"` so it paints in its first frame.
  decoded: boolean;
  /// The <img>'s onLoad: keeps its natural size and that it drew.
  onLoad(event: { currentTarget: HTMLImageElement }): void;
};

/// One chat image that never blinks or reshapes on a re-render: the same `src` every render (a sent
/// image is read and decoded once, shared by every bubble that shows it), its size before it decodes
/// (`meta`, else a previous draw or its header), and whether it should fade in (its first draw only).
/// The reader is held, not depended on: App rebuilds it whenever a turn moves, and an id names the
/// image's bytes, so a new reader never means a new image.
export function useStableImage(source: StableImageSource, meta?: { width?: number; height?: number }): StableImage {
  const id = "id" in source ? source.id : undefined;
  const direct = "src" in source ? source.src : undefined;
  const read = "id" in source ? source.read : undefined;
  const reader = useRef(read);
  reader.current = read;
  const canRead = read !== undefined;
  const [loaded, setLoaded] = useState<{ id: string; entry?: ImageEntry }>();
  const [, measured] = useReducer((count: number) => count + 1, 0);
  // The entry this image drew from stays with it: the cache may forget the image (other images
  // pushed it out) while the bubble is still on screen, and the effect below reads only on mount
  // or a new id, so the bubble must never depend on the cache still holding what it shows.
  const held = useRef<{ id: string; entry: ImageEntry }>(undefined);
  const entry =
    id === undefined
      ? undefined
      : ((loaded?.id === id ? loaded.entry : undefined) ??
        sentImageEntry(id) ??
        (held.current?.id === id ? held.current.entry : undefined));
  if (id !== undefined && entry && held.current?.entry !== entry) held.current = { id, entry };
  useEffect(() => {
    if (id === undefined || !canRead) return;
    // Kept between this render and its effect (the pane's priming landed): draw it now.
    const kept = sentImageEntry(id);
    if (kept) {
      if (held.current?.id !== id || held.current.entry !== kept) setLoaded({ id, entry: kept });
      return;
    }
    let live = true;
    // The image kept by anyone else first (the pane's priming, another bubble) draws at once.
    const stop = watchSentImage(id, (found) => {
      if (!live) return;
      setLoaded({ id, entry: found });
      stop();
    });
    void loadSentImage(id, (key) => reader.current?.(key) ?? Promise.resolve(undefined)).then(
      (found) => live && setLoaded((before) => (before?.id === id && before.entry ? before : { id, entry: found })),
      // A read can fail after a reconnect or a session switch: the slot goes, never a stale image.
      () => live && setLoaded((before) => (before?.id === id && before.entry ? before : { id })),
    );
    return () => {
      live = false;
      stop();
    };
  }, [id, canRead]);
  const src = direct ?? entry?.src;
  const fade = useRef<{ src: string; fresh: boolean }>(undefined);
  if (src !== undefined && fade.current?.src !== src) fade.current = { src, fresh: !hasDrawn(src) };
  // A size the pane measured wins, then the producer's metadata, then the image's header.
  const size =
    (id !== undefined ? sizes.get(`id:${id}`) : undefined) ??
    (src !== undefined ? sizes.get(`src:${sourceKey(src)}`) : undefined) ??
    (meta?.width && meta.height ? { width: meta.width, height: meta.height } : undefined) ??
    entry?.size ??
    (src !== undefined ? knownImageSize(src) : undefined);
  const status = src !== undefined ? "ready" : id !== undefined && canRead && loaded?.id !== id ? "loading" : "missing";
  const onLoad = (event: { currentTarget: HTMLImageElement }) => {
    const { naturalWidth: width, naturalHeight: height, currentSrc } = event.currentTarget;
    const drawnSrc = src ?? currentSrc;
    const natural = width && height ? { width, height } : undefined;
    markDrawn(drawnSrc, natural);
    if (id !== undefined && natural) rememberImageSize({ id }, natural);
    // A header that said another size (or none) reserves the frame again at the real one.
    if (natural && (natural.width !== size?.width || natural.height !== size?.height)) measured();
  };
  return {
    ...(src !== undefined && { src }),
    ...(size && { width: size.width, height: size.height }),
    status,
    fresh: fade.current?.fresh ?? true,
    decoded: entry?.decoded === true || (src !== undefined && hasDrawn(src)),
    onLoad,
  };
}

/// Forgets every image (tests).
export function clearImageEntries(): void {
  entries.clear();
  entryChars = 0;
  reading.clear();
  sizes.clear();
  drawn.clear();
  headless.clear();
}

// --- Image headers -----------------------------------------------------------------------------

/// The pixel size a base64 data URL's image header declares (PNG, GIF, WebP, JPEG with its EXIF
/// orientation), or undefined for any other source or a header it cannot read.
export function dataUrlImageSize(src: string): ImageSize | undefined {
  const comma = src.indexOf(",");
  if (!src.startsWith("data:image/") || comma < 0 || !/;base64$/i.test(src.slice(0, comma))) return undefined;
  const body = src.slice(comma + 1);
  const bytes = (length: number) => {
    const chars = Math.min(body.length, Math.ceil(length / 3) * 4);
    try {
      const text = atob(body.slice(0, chars - (chars % 4)));
      const out = new Uint8Array(text.length);
      for (let index = 0; index < text.length; index++) out[index] = text.charCodeAt(index);
      return out;
    } catch {
      return undefined;
    }
  };
  const head = bytes(32);
  if (!head || head.length < 10) return undefined;
  const size = (width: number, height: number) => (width > 0 && height > 0 ? { width, height } : undefined);
  const u16be = (b: Uint8Array, at: number) => (b[at]! << 8) | b[at + 1]!;
  const u16le = (b: Uint8Array, at: number) => b[at]! | (b[at + 1]! << 8);
  const u32be = (b: Uint8Array, at: number) =>
    ((b[at]! << 24) | (b[at + 1]! << 16) | (b[at + 2]! << 8) | b[at + 3]!) >>> 0;
  // PNG: the IHDR chunk's width and height.
  if (head[0] === 0x89 && head[1] === 0x50 && head[2] === 0x4e && head[3] === 0x47 && head.length >= 24)
    return size(u32be(head, 16), u32be(head, 20));
  // GIF: the logical screen size.
  if (head[0] === 0x47 && head[1] === 0x49 && head[2] === 0x46) return size(u16le(head, 6), u16le(head, 8));
  // WebP: lossy (VP8), lossless (VP8L) or extended (VP8X).
  if (head[0] === 0x52 && head[1] === 0x49 && head[8] === 0x57 && head[9] === 0x45 && head.length >= 30) {
    const chunk = String.fromCharCode(head[12]!, head[13]!, head[14]!, head[15]!);
    if (chunk === "VP8 ") return size(u16le(head, 26) & 0x3fff, u16le(head, 28) & 0x3fff);
    if (chunk === "VP8L") {
      const bits = head[21]! | (head[22]! << 8) | (head[23]! << 16) | (head[24]! << 24);
      return size((bits & 0x3fff) + 1, ((bits >>> 14) & 0x3fff) + 1);
    }
    if (chunk === "VP8X")
      return size(
        1 + (head[24]! | (head[25]! << 8) | (head[26]! << 16)),
        1 + (head[27]! | (head[28]! << 8) | (head[29]! << 16)),
      );
    return undefined;
  }
  // JPEG: the first start-of-frame segment, past any EXIF (read for its orientation).
  if (head[0] === 0xff && head[1] === 0xd8) {
    const jpeg = bytes(256 * 1024);
    if (!jpeg) return undefined;
    let rotated = false;
    for (let at = 2; at + 9 < jpeg.length;) {
      if (jpeg[at] !== 0xff) return undefined;
      const marker = jpeg[at + 1]!;
      if (marker === 0xff) {
        at += 1;
        continue;
      }
      const length = u16be(jpeg, at + 2);
      if (marker === 0xe1) rotated ||= exifRotates(jpeg, at + 4, at + 2 + length);
      // SOF0-SOF15, but not DHT (C4), JPG (C8) or DAC (CC).
      if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
        const height = u16be(jpeg, at + 5);
        const width = u16be(jpeg, at + 7);
        return rotated ? size(height, width) : size(width, height);
      }
      at += 2 + length;
    }
  }
  return undefined;
}

/// Whether an APP1 segment's EXIF orientation turns the image a quarter (5-8), which the engine
/// applies, so it draws with its width and height swapped.
function exifRotates(b: Uint8Array, start: number, end: number): boolean {
  if (end > b.length || String.fromCharCode(...b.subarray(start, start + 4)) !== "Exif") return false;
  const tiff = start + 6;
  const little = b[tiff] === 0x49;
  const u16 = (at: number) => (little ? b[at]! | (b[at + 1]! << 8) : (b[at]! << 8) | b[at + 1]!);
  const u32 = (at: number) =>
    (little
      ? b[at]! | (b[at + 1]! << 8) | (b[at + 2]! << 16) | (b[at + 3]! << 24)
      : (b[at]! << 24) | (b[at + 1]! << 16) | (b[at + 2]! << 8) | b[at + 3]!) >>> 0;
  const ifd = tiff + u32(tiff + 4);
  if (ifd + 2 > end) return false;
  const count = u16(ifd);
  for (let index = 0; index < count; index++) {
    const entry = ifd + 2 + index * 12;
    if (entry + 12 > end) return false;
    if (u16(entry) === 0x0112) return u16(entry + 8) >= 5;
  }
  return false;
}
