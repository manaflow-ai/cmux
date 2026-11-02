// Attachments in the Channels view: preparing a file (its SHA-256, size, dimensions and a derived
// preview or poster image), the owner's chunked upload with progress, and reading stored bytes back.
// The owner (home-messaging.md section 2; the daemon's `conversation-attachment-*` commands) checks
// every rule again; the page checks the allow list and the size first only to say so at once.
//
// Images, previews and posters come back as data URLs read over the page's own connection, so they
// show under any page policy (the app's page scheme allows `img-src data:` only). A video plays
// from a short-lived URL on the daemon's listener, which answers byte ranges (seeking); a page
// whose policy has no `media-src` for that origin (the app's page scheme today) cannot play it.
import type { PageClient } from "../shared/pageClient";
import { imageSize, MAX_DECODE_PIXELS, MAX_UNSIZED_DECODE_BYTES } from "../../agent-session/acpmux/composer/imageWork";
import {
  HomeOps,
  MESSAGE_PARTS,
  type HomeAttachment,
  type HomeAttachmentSupport,
  type HomeDerivedImage,
} from "./types";

export type AttachmentClass = "image" | "video" | "audio" | "file";

/** A file with no listed type that does not read as UTF-8 text (home-core GENERIC_FILE_TYPE). */
export const GENERIC_FILE_TYPE = "application/octet-stream";

/** The owner's types (home-core attachments.ts ATTACHMENT_TYPES). Any file attaches: a file with no
 * listed type goes as text/plain when its bytes read as UTF-8 (HTML, source code, dotfiles), else
 * as GENERIC_FILE_TYPE (`resolvedType`). */
const TYPES: Readonly<Record<string, AttachmentClass>> = {
  "image/jpeg": "image",
  "image/png": "image",
  "image/gif": "image",
  "image/webp": "image",
  "image/heic": "image",
  "application/pdf": "file",
  "text/plain": "file",
  "text/markdown": "file",
  "text/csv": "file",
  "application/json": "file",
  "application/zip": "file",
  [GENERIC_FILE_TYPE]: "file",
  "video/mp4": "video",
  "video/quicktime": "video",
  "audio/mp4": "audio",
  "audio/mpeg": "audio",
  "audio/aac": "audio",
  "audio/wav": "audio",
};
/** Types a browser reports under another name, by extension. */
const BY_EXTENSION: Readonly<Record<string, string>> = {
  md: "text/markdown",
  markdown: "text/markdown",
  csv: "text/csv",
  json: "application/json",
  txt: "text/plain",
  log: "text/plain",
  mov: "video/quicktime",
  m4a: "audio/mp4",
  heic: "image/heic",
};

const PREVIEW_BYTES_LIMIT = 512_000;
const POSTER_BYTES_LIMIT = 2_000_000;
const PREVIEW_EDGE = 720;
const POSTER_EDGE = 1280;
/** Upload chunk (decoded): about 1.4 MB of base64 per frame. */
const CHUNK_BYTES = 1024 * 1024;
/** Read chunk: a multiple of 3, so base64 pieces join into one string. */
const READ_BYTES = 3 * 1024 * 1024;
/** Images up to this size come back as data URLs; a larger one shows from its URL. */
const DATA_URL_BYTES_LIMIT = 16_000_000;
/** Image data URLs kept (least recently used goes first). */
const IMAGE_CACHE_ENTRIES = 64;
/** The longest wait for the browser to read a video's first frame. */
const FACTS_TIMEOUT_MS = 5_000;

export function attachmentClass(mimeType: string): AttachmentClass {
  return TYPES[mimeType] ?? "file";
}

/** The listed type the owner will see for `file` from its declared type or extension, or undefined
 * when it has none (`resolvedType` then reads its bytes). */
export function attachmentType(file: File): string | undefined {
  const declared = file.type.toLowerCase();
  if (TYPES[declared] && declared !== GENERIC_FILE_TYPE) return declared;
  const extension = file.name.slice(file.name.lastIndexOf(".") + 1).toLowerCase();
  const guessed = BY_EXTENSION[extension];
  return guessed && TYPES[guessed] ? guessed : undefined;
}

/** How many leading bytes the text check reads. */
const SNIFF_BYTES = 64 * 1024;

/** True when `bytes` read as UTF-8 text: no NUL, valid UTF-8 (a character cut at the end of a
 * prefix counts unless `complete`), and almost no control characters besides tab, line breaks,
 * form feed and escape. Matches CmuxHomeCore's HomeAttachmentPolicy.looksLikeText. */
export function looksLikeText(bytes: Uint8Array, complete: boolean): boolean {
  let controls = 0;
  for (const byte of bytes) {
    if (byte === 0) return false;
    if (byte < 0x20 && byte !== 0x09 && byte !== 0x0a && byte !== 0x0c && byte !== 0x0d && byte !== 0x1b) controls += 1;
  }
  if (controls * 100 > Math.max(bytes.length, 1)) return false;
  const decoder = () => new TextDecoder("utf-8", { fatal: true });
  for (let cut = 0; cut <= (complete ? 0 : Math.min(3, bytes.length)); cut += 1) {
    try {
      decoder().decode(bytes.subarray(0, bytes.length - cut));
      return true;
    } catch {
      // try a shorter prefix: the last character may be cut
    }
  }
  return false;
}

/** The type the owner will see for `file` whose bytes are `bytes`: its listed type, else text/plain
 * for UTF-8 text, else GENERIC_FILE_TYPE. */
export function resolvedType(file: File, bytes: Uint8Array): string {
  const listed = attachmentType(file);
  if (listed) return listed;
  const prefix = bytes.subarray(0, SNIFF_BYTES);
  return looksLikeText(prefix, file.size <= prefix.length) ? "text/plain" : GENERIC_FILE_TYPE;
}

export type Refusal = "size";

/** Why the owner would refuse `file`, before any byte moves: only an empty file is refused. */
export function refusal(file: File): Refusal | undefined {
  if (file.size <= 0) return "size";
  return undefined;
}

/** The messages one send of `text` and `files` becomes, in order: each within `MESSAGE_PARTS`, the
 * text (when there is any) with the first files. No files: the text alone. */
export function messageGroups<T>(text: string, files: readonly T[]): { text: string; files: T[] }[] {
  const groups: { text: string; files: T[] }[] = [];
  let at = 0;
  let first = true;
  do {
    const room = MESSAGE_PARTS - (first && text ? 1 : 0);
    groups.push({ text: first ? text : "", files: files.slice(at, at + room) });
    at += room;
    first = false;
  } while (at < files.length);
  return groups;
}

export function formatBytes(bytes: number): string {
  const units = ["B", "KB", "MB", "GB"];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value < 10 && unit > 0 ? value.toFixed(1) : Math.round(value)} ${units[unit]}`;
}

/** Incremental SHA-256 so an attachment's hash never requires a whole-file allocation. */
class StreamingSha256 {
  private readonly state = new Uint32Array([
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ]);
  private readonly pending = new Uint8Array(64);
  private readonly words = new Uint32Array(64);
  private pendingLength = 0;
  private bytes = 0;

  update(input: Uint8Array): void {
    this.bytes += input.length;
    let offset = 0;
    if (this.pendingLength) {
      const count = Math.min(64 - this.pendingLength, input.length);
      this.pending.set(input.subarray(0, count), this.pendingLength);
      this.pendingLength += count;
      offset = count;
      if (this.pendingLength === 64) {
        this.block(this.pending);
        this.pendingLength = 0;
      }
    }
    while (offset + 64 <= input.length) {
      this.block(input.subarray(offset, offset + 64));
      offset += 64;
    }
    if (offset < input.length) {
      this.pending.set(input.subarray(offset), 0);
      this.pendingLength = input.length - offset;
    }
  }

  digest(): string {
    const tail = new Uint8Array(128);
    tail.set(this.pending.subarray(0, this.pendingLength));
    tail[this.pendingLength] = 0x80;
    const bitLength = this.bytes * 8;
    const blockLength = this.pendingLength + 1 <= 56 ? 64 : 128;
    const view = new DataView(tail.buffer);
    view.setUint32(blockLength - 8, Math.floor(bitLength / 0x1_0000_0000));
    view.setUint32(blockLength - 4, bitLength >>> 0);
    this.block(tail.subarray(0, 64));
    if (blockLength === 128) this.block(tail.subarray(64, 128));
    return [...this.state].map((word) => word.toString(16).padStart(8, "0")).join("");
  }

  private block(block: Uint8Array): void {
    const words = this.words;
    const view = new DataView(block.buffer, block.byteOffset, block.byteLength);
    for (let i = 0; i < 16; i++) words[i] = view.getUint32(i * 4);
    for (let i = 16; i < 64; i++) {
      const x = words[i - 15]!,
        y = words[i - 2]!;
      const s0 = ((x >>> 7) | (x << 25)) ^ ((x >>> 18) | (x << 14)) ^ (x >>> 3);
      const s1 = ((y >>> 17) | (y << 15)) ^ ((y >>> 19) | (y << 13)) ^ (y >>> 10);
      words[i] = (words[i - 16]! + s0 + words[i - 7]! + s1) >>> 0;
    }
    let [a, b, c, d, e, f, g, h] = this.state;
    for (let i = 0; i < 64; i++) {
      const s1 = ((e! >>> 6) | (e! << 26)) ^ ((e! >>> 11) | (e! << 21)) ^ ((e! >>> 25) | (e! << 7));
      const choose = (e! & f!) ^ (~e! & g!);
      const t1 = (h! + s1 + choose + K[i]! + words[i]!) >>> 0;
      const s0 = ((a! >>> 2) | (a! << 30)) ^ ((a! >>> 13) | (a! << 19)) ^ ((a! >>> 22) | (a! << 10));
      const majority = (a! & b!) ^ (a! & c!) ^ (b! & c!);
      const t2 = (s0 + majority) >>> 0;
      const nextA = (t1 + t2) >>> 0;
      const nextE = (d! + t1) >>> 0;
      h = g;
      g = f;
      f = e;
      e = nextE;
      d = c;
      c = b;
      b = a;
      a = nextA;
    }
    this.state[0] = (this.state[0]! + a!) >>> 0;
    this.state[1] = (this.state[1]! + b!) >>> 0;
    this.state[2] = (this.state[2]! + c!) >>> 0;
    this.state[3] = (this.state[3]! + d!) >>> 0;
    this.state[4] = (this.state[4]! + e!) >>> 0;
    this.state[5] = (this.state[5]! + f!) >>> 0;
    this.state[6] = (this.state[6]! + g!) >>> 0;
    this.state[7] = (this.state[7]! + h!) >>> 0;
  }
}

const K = Uint32Array.from([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98,
  0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8,
  0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819,
  0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
  0xc67178f2,
]);

async function sha256(bytes: ArrayBuffer | Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes as BufferSource);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function hashFile(file: File, signal?: AbortSignal): Promise<string> {
  const hash = new StreamingSha256();
  for (let offset = 0; offset < file.size; offset += READ_BYTES) {
    if (signal?.aborted) throw new DOMException("cancelled", "AbortError");
    hash.update(new Uint8Array(await file.slice(offset, offset + READ_BYTES).arrayBuffer()));
  }
  return hash.digest();
}

function base64(bytes: Uint8Array): string {
  let binary = "";
  for (let index = 0; index < bytes.length; index += 0x8000)
    binary += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
  return btoa(binary);
}

interface Derived {
  bytes: Uint8Array;
  mimeType: string;
}

/** What the browser learned about a file before its upload. */
interface Facts {
  width?: number;
  height?: number;
  durationMs?: number;
  preview?: Derived;
  poster?: Derived;
}

/** A canvas frame as JPEG within `maxBytes` (lower quality, then a smaller edge). */
async function jpeg(source: CanvasImageSource, width: number, height: number, edge: number, maxBytes: number) {
  let scale = Math.min(1, edge / Math.max(width, height, 1));
  for (let attempt = 0; attempt < 4; attempt += 1) {
    const canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round(width * scale));
    canvas.height = Math.max(1, Math.round(height * scale));
    canvas.getContext("2d")?.drawImage(source, 0, 0, canvas.width, canvas.height);
    for (const quality of [0.82, 0.68, 0.5]) {
      const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, "image/jpeg", quality));
      if (blob && blob.size <= maxBytes)
        return { bytes: new Uint8Array(await blob.arrayBuffer()), mimeType: "image/jpeg" };
    }
    scale *= 0.6;
  }
  return undefined;
}

/** An image's size and small preview (none for a GIF, which would stop moving, or a type the
 * browser cannot decode). */
async function imageFacts(file: File, mimeType: string): Promise<Facts> {
  const size = await imageSize(file).catch(() => undefined);
  if (
    size &&
    (size.width === undefined ||
      size.height === undefined ||
      (size.height > 0 && size.width > MAX_DECODE_PIXELS / size.height))
  )
    return {};
  const heic = mimeType === "image/heic";
  // Follow the shared unsized-image decode budget. This limits only optional preview work;
  // the original is still hashed and uploaded in slices, regardless of its byte count.
  if (!size && (!heic || file.size > MAX_UNSIZED_DECODE_BYTES)) return {};
  const bitmap = await createImageBitmap(file).catch(() => undefined);
  if (!bitmap) return {};
  const facts = { width: bitmap.width, height: bitmap.height };
  const small = file.size <= PREVIEW_BYTES_LIMIT && Math.max(bitmap.width, bitmap.height) <= PREVIEW_EDGE;
  const preview =
    mimeType === "image/gif" || (small && !heic)
      ? undefined
      : await jpeg(bitmap, bitmap.width, bitmap.height, PREVIEW_EDGE, PREVIEW_BYTES_LIMIT).catch(() => undefined);
  bitmap.close();
  return preview ? { ...facts, preview } : facts;
}

/** A video's size, length and poster (a frame near its start), when the browser can decode it. */
async function videoFacts(file: File): Promise<Facts> {
  const url = URL.createObjectURL(file);
  const video = document.createElement("video");
  video.muted = true;
  video.playsInline = true;
  video.preload = "auto";
  // A file the browser cannot decode may fire nothing: give up after a few seconds (no poster).
  const once = (name: string) =>
    new Promise<boolean>((resolve) => {
      const timer = setTimeout(() => resolve(false), FACTS_TIMEOUT_MS);
      const done = (value: boolean) => {
        clearTimeout(timer);
        resolve(value);
      };
      video.addEventListener(name, () => done(true), { once: true });
      video.addEventListener("error", () => done(false), { once: true });
    });
  try {
    const loaded = once("loadeddata");
    video.src = url;
    if (!(await loaded)) return {};
    const facts = {
      width: video.videoWidth || undefined,
      height: video.videoHeight || undefined,
      durationMs: Number.isFinite(video.duration) ? Math.round(video.duration * 1000) : undefined,
    };
    const seeked = once("seeked");
    video.currentTime = Math.min(1, (video.duration || 0) / 10);
    if (!(await seeked) || !video.videoWidth) return facts;
    const poster = await jpeg(video, video.videoWidth, video.videoHeight, POSTER_EDGE, POSTER_BYTES_LIMIT).catch(
      () => undefined,
    );
    return poster ? { ...facts, poster } : facts;
  } finally {
    video.removeAttribute("src");
    video.load();
    URL.revokeObjectURL(url);
  }
}

export interface UploadProgress {
  sent: number;
  total: number;
}

type UploadReply = { upload?: string | null; needs?: string[]; stored?: unknown; received?: number };

/** The page's attachment work against one host: upload, read, link. One per page client. */
export class AttachmentService {
  private supported: Promise<HomeAttachmentSupport> | null = null;
  private readonly images = new Map<string, Promise<string>>();
  private readonly urls = new Map<string, { url: Promise<string>; until: number }>();

  constructor(private readonly client: PageClient) {}

  /** Which owners take attachments here (an older host: none). */
  support(): Promise<HomeAttachmentSupport> {
    this.supported ??= this.client
      .call<HomeAttachmentSupport>(HomeOps.attachmentSupport, {})
      .catch(() => ({ local: false, cloud: false }));
    return this.supported;
  }

  /** Hashes, measures and uploads `file` (with its derived image) to `conversation`; the part a
   * message then names. `signal` cancels the upload. */
  async upload(
    conversation: string,
    file: File,
    onProgress: (progress: UploadProgress) => void,
    signal?: AbortSignal,
  ): Promise<HomeAttachment> {
    if (refusal(file)) throw new Error("refused");
    const prefix = new Uint8Array(await file.slice(0, Math.min(SNIFF_BYTES, file.size)).arrayBuffer());
    const mimeType = resolvedType(file, prefix);
    const kind = attachmentClass(mimeType);
    const facts: Facts =
      kind === "image" ? await imageFacts(file, mimeType) : kind === "video" ? await videoFacts(file) : {};
    const derived = facts.preview ?? facts.poster;
    const part: HomeAttachment = {
      type: "attachment",
      hash: await hashFile(file, signal),
      name: file.name,
      mimeType,
      byteCount: file.size,
    };
    if (facts.width) part.width = facts.width;
    if (facts.height) part.height = facts.height;
    if (facts.durationMs !== undefined) part.durationMs = facts.durationMs;
    let derivedImage: HomeDerivedImage | undefined;
    if (derived) {
      derivedImage = { hash: await sha256(derived.bytes), mimeType: derived.mimeType, byteCount: derived.bytes.length };
      if (kind === "video") part.poster = derivedImage;
      else part.preview = derivedImage;
    }
    const declared = derivedImage
      ? { sha256: derivedImage.hash, byte_count: derivedImage.byteCount, mime_type: derivedImage.mimeType }
      : undefined;
    const begun = await this.client.call<UploadReply>(HomeOps.attachmentUpload, {
      op: "begin",
      conversation,
      sha256: part.hash,
      byte_count: part.byteCount,
      mime_type: mimeType,
      name: file.name,
      ...(part.width ? { width: part.width } : {}),
      ...(part.height ? { height: part.height } : {}),
      ...(part.durationMs !== undefined ? { duration_ms: part.durationMs } : {}),
      ...(declared ? { [kind === "video" ? "poster" : "preview"]: declared } : {}),
    });
    const total = file.size + (derived?.bytes.length ?? 0);
    // The conversation already holds these bytes (the first record of a hash wins: send what it kept).
    if (!begun.upload) {
      onProgress({ sent: total, total });
      return kept(part, begun.stored);
    }
    const upload = begun.upload;
    let sent = 0;
    try {
      for (const piece of begun.needs ?? []) {
        const data = piece === "original" ? undefined : derived?.bytes;
        if (piece !== "original" && !data) throw new Error(`no bytes for ${piece}`);
        const size = piece === "original" ? file.size : data!.length;
        for (let offset = 0; offset < size; offset += CHUNK_BYTES) {
          if (signal?.aborted) throw new DOMException("cancelled", "AbortError");
          const chunk =
            piece === "original"
              ? new Uint8Array(await file.slice(offset, offset + CHUNK_BYTES).arrayBuffer())
              : data!.subarray(offset, offset + CHUNK_BYTES);
          await this.client.call(HomeOps.attachmentUpload, { op: "chunk", upload, piece, offset, data: base64(chunk) });
          sent += chunk.length;
          onProgress({ sent, total });
        }
      }
      const committed = await this.client.call<UploadReply>(HomeOps.attachmentUpload, { op: "commit", upload });
      onProgress({ sent: total, total });
      return kept(part, committed.stored);
    } catch (error) {
      void this.client.call(HomeOps.attachmentUpload, { op: "cancel", upload }).catch(() => undefined);
      throw error;
    }
  }

  /** An image variant as a data URL (cached for the page's life; bytes never change by hash). */
  image(conversation: string, image: { hash: string; variant: "original" | "preview" | "poster" }): Promise<string> {
    const key = `${conversation}:${image.hash}:${image.variant}`;
    let found = this.images.get(key);
    if (found) this.images.delete(key);
    else {
      found = this.readDataUrl(conversation, image.hash, image.variant);
      found.catch(() => this.images.delete(key));
    }
    // Most recent last; the oldest leaves when the cache is full.
    this.images.set(key, found);
    while (this.images.size > IMAGE_CACHE_ENTRIES) this.images.delete(this.images.keys().next().value as string);
    return found;
  }

  /** A URL of one variant on the daemon's listener (video, large images, downloads). `fresh` asks
   * for a new link (the old one stopped answering: it ended, or the daemon restarted). */
  url(
    conversation: string,
    hash: string,
    variant: "original" | "preview" | "poster",
    name?: string,
    fresh = false,
  ): Promise<string> {
    const key = `${conversation}:${hash}:${variant}:${name ?? ""}`;
    const now = Date.now();
    const cached = this.urls.get(key);
    if (cached && cached.until > now && !fresh) return cached.url;
    const url = this.client
      .call<{ url: string; expiresInMs: number }>(HomeOps.attachmentUrl, {
        conversation,
        hash,
        variant,
        ...(name ? { name } : {}),
      })
      .then((link) => {
        // Renew a minute early: a player that seeks after that asks again.
        this.urls.set(key, { url, until: Date.now() + Math.max(0, link.expiresInMs - 60_000) });
        return link.url;
      });
    url.catch(() => this.urls.delete(key));
    this.urls.set(key, { url, until: now + 30_000 });
    return url;
  }

  /** Whether an image of this size comes back as a data URL (else from its URL). */
  static inline(byteCount: number): boolean {
    return byteCount <= DATA_URL_BYTES_LIMIT;
  }

  private async readDataUrl(conversation: string, hash: string, variant: string): Promise<string> {
    let offset = 0;
    let data = "";
    let mimeType = "application/octet-stream";
    for (;;) {
      const read = await this.client.call<{ mimeType: string; data: string; eof: boolean; byteCount: number }>(
        HomeOps.attachmentRead,
        { conversation, hash, variant, offset, length: READ_BYTES },
      );
      mimeType = read.mimeType || mimeType;
      // Whole base64 quanta only join: every read but the last is a multiple of 3 bytes.
      const padding = read.data.endsWith("==") ? 2 : read.data.endsWith("=") ? 1 : 0;
      const decoded = (read.data.length / 4) * 3 - padding;
      if (!read.eof && decoded % 3 !== 0) throw new Error("short read");
      data += read.data;
      offset += decoded;
      if (read.eof || decoded === 0 || offset >= read.byteCount) break;
    }
    // Only raster images become data URLs (never a type that could run as a document).
    if (!/^image\/(jpeg|png|gif|webp|heic)$/.test(mimeType)) throw new Error("not an image");
    return `data:${mimeType};base64,${data}`;
  }
}

/** The part as the owner keeps it: a hash it already held keeps its first record's derived image. */
function kept(part: HomeAttachment, stored: unknown): HomeAttachment {
  if (!stored || typeof stored !== "object") return part;
  const record = stored as { poster?: Record<string, unknown>; preview?: Record<string, unknown> };
  const image = (raw?: Record<string, unknown>): HomeDerivedImage | undefined =>
    raw ? { hash: String(raw.hash), mimeType: String(raw.mime_type), byteCount: Number(raw.byte_count) } : undefined;
  const { poster: _poster, preview: _preview, ...rest } = part;
  const result: HomeAttachment = { ...rest };
  const poster = image(record.poster);
  const preview = image(record.preview);
  if (poster) result.poster = poster;
  if (preview) result.preview = preview;
  return result;
}
