// Minimal PNG encoder plus PNG/JPEG dimension sniffing. No dependencies.
import { deflateSync } from "node:zlib";

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(buf: Uint8Array): number {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type: string, data: Uint8Array): Uint8Array {
  const out = new Uint8Array(12 + data.length);
  const dv = new DataView(out.buffer);
  dv.setUint32(0, data.length);
  for (let i = 0; i < 4; i++) out[4 + i] = type.charCodeAt(i);
  out.set(data, 8);
  dv.setUint32(8 + data.length, crc32(out.subarray(4, 8 + data.length)));
  return out;
}

export const PNG_SIGNATURE = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

/** Encode 8-bit RGB pixels (length w*h*3) as a PNG. */
export function encodePNG(width: number, height: number, rgb: Uint8Array): Uint8Array {
  const ihdr = new Uint8Array(13);
  const dv = new DataView(ihdr.buffer);
  dv.setUint32(0, width);
  dv.setUint32(4, height);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 2; // color type RGB
  const stride = width * 3;
  const raw = new Uint8Array((stride + 1) * height);
  for (let y = 0; y < height; y++) {
    raw[y * (stride + 1)] = 0; // filter: none
    raw.set(rgb.subarray(y * stride, (y + 1) * stride), y * (stride + 1) + 1);
  }
  const idat = new Uint8Array(deflateSync(raw, { level: 6 }));
  const parts = [PNG_SIGNATURE, chunk("IHDR", ihdr), chunk("IDAT", idat), chunk("IEND", new Uint8Array(0))];
  const total = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(total);
  let off = 0;
  for (const p of parts) {
    out.set(p, off);
    off += p.length;
  }
  return out;
}

function hashString(s: string): number {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

export function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function hsl(h: number, s: number, l: number): [number, number, number] {
  const k = (n: number) => (n + h / 30) % 12;
  const a = s * Math.min(l, 1 - l);
  const f = (n: number) => l - a * Math.max(-1, Math.min(k(n) - 3, Math.min(9 - k(n), 1)));
  return [Math.round(f(0) * 255), Math.round(f(8) * 255), Math.round(f(4) * 255)];
}

/** Longest edge capped at `cap`, aspect ratio preserved. */
export function cappedSize(width: number, height: number, cap = 1200): [number, number] {
  const longest = Math.max(width, height);
  if (longest <= cap) return [Math.max(1, Math.round(width)), Math.max(1, Math.round(height))];
  const s = cap / longest;
  return [Math.max(1, Math.round(width * s)), Math.max(1, Math.round(height * s))];
}

/** Procedural image seeded by id: diagonal gradient plus a few circles and rectangles. */
export function proceduralPNG(id: string, width: number, height: number): Uint8Array {
  const [w, h] = cappedSize(width, height);
  const rnd = mulberry32(hashString(id));
  const hue = rnd() * 360;
  const c0 = hsl(hue, 0.55 + rnd() * 0.3, 0.35 + rnd() * 0.2);
  const c1 = hsl((hue + 60 + rnd() * 120) % 360, 0.55 + rnd() * 0.3, 0.55 + rnd() * 0.2);
  const shapes = Array.from({ length: 3 + Math.floor(rnd() * 5) }, () => ({
    circle: rnd() < 0.6,
    x: rnd() * w,
    y: rnd() * h,
    r: (0.06 + rnd() * 0.22) * Math.min(w, h),
    rw: (0.1 + rnd() * 0.35) * w,
    rh: (0.1 + rnd() * 0.35) * h,
    color: hsl((hue + rnd() * 360) % 360, 0.6, 0.45 + rnd() * 0.35),
    alpha: 0.35 + rnd() * 0.5,
  }));
  const rgb = new Uint8Array(w * h * 3);
  const denom = Math.max(1, w + h - 2);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const t = (x + y) / denom;
      let r = c0[0] + (c1[0] - c0[0]) * t;
      let g = c0[1] + (c1[1] - c0[1]) * t;
      let b = c0[2] + (c1[2] - c0[2]) * t;
      for (const s of shapes) {
        let inside: boolean;
        if (s.circle) {
          const dx = x - s.x;
          const dy = y - s.y;
          inside = dx * dx + dy * dy <= s.r * s.r;
        } else {
          inside = x >= s.x && x < s.x + s.rw && y >= s.y && y < s.y + s.rh;
        }
        if (inside) {
          r += (s.color[0] - r) * s.alpha;
          g += (s.color[1] - g) * s.alpha;
          b += (s.color[2] - b) * s.alpha;
        }
      }
      const i = (y * w + x) * 3;
      rgb[i] = r;
      rgb[i + 1] = g;
      rgb[i + 2] = b;
    }
  }
  return encodePNG(w, h, rgb);
}

/** Parse width/height from PNG IHDR or JPEG SOFn. Returns null when unknown. */
export function sniffImageSize(buf: Uint8Array): { width: number; height: number; ext: string; mime: string } | null {
  if (buf.length >= 24 && PNG_SIGNATURE.every((b, i) => buf[i] === b)) {
    const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
    return { width: dv.getUint32(16), height: dv.getUint32(20), ext: "png", mime: "image/png" };
  }
  if (buf.length >= 4 && buf[0] === 0xff && buf[1] === 0xd8) {
    let i = 2;
    while (i + 9 < buf.length) {
      if (buf[i] !== 0xff) {
        i++;
        continue;
      }
      const marker = buf[i + 1];
      if (marker === 0xff) {
        i++;
        continue;
      }
      if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
        i += 2;
        continue;
      }
      const len = (buf[i + 2] << 8) | buf[i + 3];
      const isSOF = marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc;
      if (isSOF) {
        const height = (buf[i + 5] << 8) | buf[i + 6];
        const width = (buf[i + 7] << 8) | buf[i + 8];
        return { width, height, ext: "jpg", mime: "image/jpeg" };
      }
      if (marker === 0xda) break; // start of scan without SOF
      i += 2 + len;
    }
    return { width: 0, height: 0, ext: "jpg", mime: "image/jpeg" };
  }
  return null;
}
