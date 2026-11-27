// Procedural audio messages: deterministic speech-like WAV per media id, a
// waveform derived from the same syllable schedule, and spoken transcripts.
import { mulberry32 } from "./png";
import { pick, type Rng } from "./corpus";

export const AUDIO_SAMPLE_RATE = 16_000;
/** Messages deletes audio 2 minutes after it is sent or listened to, unless kept. */
export const AUDIO_EXPIRY_MS = 2 * 60_000;

const SPOKEN = [
  "Hey, I'm heading out now, I'll be there in like ten minutes.",
  "Okay so I looked at the crash log and it's the reconnect path again.",
  "Can you call me when you get a sec? It's about the release.",
  "Just landed, grabbing my bag and then I'll ping you.",
  "Yeah that works for me, let's do three thirty.",
  "I tried the new build on my phone and the scrolling feels way better.",
  "Running a bit late, start without me.",
  "Quick update, the nightly is green, I'm going to cut the RC tonight.",
  "Did you see the thread about the keyboard bug? I think I know what's going on.",
  "Sounds good, thanks!",
  "Can you grab coffee on your way in?",
  "So the repro is, open two workspaces, close the first one, and the sidebar jumps.",
  "I'm at the office, door's open.",
  "Let me know when the PR is up and I'll review it right away.",
  "Haha no way, that's amazing.",
];

export function spokenText(rng: Rng): string {
  return pick(rng, SPOKEN);
}

/** Roughly how long it takes to say `text` (2.6 words/s plus lead-in), 1.2-30 s. */
export function spokenDurationMs(text: string, rng: Rng): number {
  const words = text.split(/\s+/).filter(Boolean).length;
  const seconds = 0.7 + words / 2.6 + rng() * 0.8;
  return Math.round(Math.min(30, Math.max(1.2, seconds)) * 1000);
}

function hashSeed(id: string): number {
  let h = 2166136261;
  for (let i = 0; i < id.length; i++) {
    h ^= id.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

interface Syllable {
  start: number; // samples
  length: number;
  pitch: number;
  loudness: number;
}

function schedule(id: string, durationMs: number): { total: number; syllables: Syllable[] } {
  const rng = mulberry32(hashSeed(id));
  const total = Math.round((durationMs / 1000) * AUDIO_SAMPLE_RATE);
  const syllables: Syllable[] = [];
  // A short breath of silence first, as real recordings have.
  let pos = Math.round((0.12 + rng() * 0.15) * AUDIO_SAMPLE_RATE);
  const tail = Math.round(0.2 * AUDIO_SAMPLE_RATE);
  while (pos < total - tail) {
    const length = Math.round((0.09 + rng() * 0.17) * AUDIO_SAMPLE_RATE);
    const pause = rng() < 0.14 ? 0.22 + rng() * 0.3 : 0.03 + rng() * 0.09;
    syllables.push({ start: pos, length: Math.min(length, total - tail - pos), pitch: 105 + rng() * 95, loudness: 0.3 + rng() * 0.6 });
    pos += length + Math.round(pause * AUDIO_SAMPLE_RATE);
  }
  return { total, syllables };
}

/** Peak level per bucket, 0-100, `count` buckets over the recording (meter dB mapping). */
export function audioWaveform(id: string, durationMs: number, count = Math.min(120, Math.max(12, Math.round(durationMs / 50)))): number[] {
  const { total, syllables } = schedule(id, durationMs);
  const out = new Array<number>(count).fill(0);
  for (const s of syllables) {
    const from = Math.floor((s.start / total) * count);
    const to = Math.min(count - 1, Math.floor(((s.start + s.length) / total) * count));
    for (let b = from; b <= to; b++) {
      // Envelope peak inside this bucket (sin hump).
      const bucketStart = (b / count) * total;
      const bucketEnd = ((b + 1) / count) * total;
      const mid = s.start + s.length / 2;
      const nearest = Math.min(Math.max(mid, bucketStart), bucketEnd);
      const u = (nearest - s.start) / s.length;
      const amp = Math.sin(Math.PI * Math.min(1, Math.max(0, u))) * s.loudness * 0.7;
      const db = 20 * Math.log10(Math.max(1e-6, amp));
      const level = Math.max(0, Math.min(1, (db + 50) / 50));
      out[b] = Math.max(out[b], Math.round(level * 100));
    }
  }
  return out;
}

/** 16-bit mono PCM WAV of the recording. */
export function proceduralWAV(id: string, durationMs: number): Uint8Array {
  const { total, syllables } = schedule(id, durationMs);
  const noise = mulberry32(hashSeed(id) ^ 0x5bd1e995);
  const pcm = new Float32Array(total);
  for (const s of syllables) {
    let phase = 0;
    for (let i = 0; i < s.length; i++) {
      const u = i / s.length;
      const env = Math.sin(Math.PI * u) * s.loudness;
      // A little vibrato so it reads as a voice, not a tone.
      const f = s.pitch * (1 + 0.04 * Math.sin(2 * Math.PI * 5 * (i / AUDIO_SAMPLE_RATE)));
      phase += (2 * Math.PI * f) / AUDIO_SAMPLE_RATE;
      const v = Math.sin(phase) * 0.55 + Math.sin(2 * phase) * 0.25 + Math.sin(3 * phase) * 0.12 + (noise() - 0.5) * 0.06;
      pcm[s.start + i] = v * env;
    }
  }
  return encodeWAV(pcm);
}

export function encodeWAV(pcm: Float32Array, sampleRate = AUDIO_SAMPLE_RATE): Uint8Array {
  const bytes = new Uint8Array(44 + pcm.length * 2);
  const view = new DataView(bytes.buffer);
  const ascii = (offset: number, s: string) => [...s].forEach((c, i) => view.setUint8(offset + i, c.charCodeAt(0)));
  ascii(0, "RIFF");
  view.setUint32(4, 36 + pcm.length * 2, true);
  ascii(8, "WAVEfmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  ascii(36, "data");
  view.setUint32(40, pcm.length * 2, true);
  for (let i = 0; i < pcm.length; i++) view.setInt16(44 + i * 2, Math.round(Math.max(-1, Math.min(1, pcm[i])) * 32767), true);
  return bytes;
}

/** Duration of a PCM WAV upload, or null when the bytes are not WAV. */
export function sniffWAVDurationMs(bytes: Uint8Array): number | null {
  if (bytes.length < 44) return null;
  const tag = (o: number) => String.fromCharCode(...bytes.slice(o, o + 4));
  if (tag(0) !== "RIFF" || tag(8) !== "WAVE") return null;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let offset = 12;
  let byteRate = 0;
  while (offset + 8 <= bytes.length) {
    const id = tag(offset);
    const size = view.getUint32(offset + 4, true);
    if (id === "fmt ") byteRate = view.getUint32(offset + 16, true);
    if (id === "data" && byteRate > 0) return Math.round((Math.min(size, bytes.length - offset - 8) / byteRate) * 1000);
    offset += 8 + size + (size % 2);
  }
  return null;
}
