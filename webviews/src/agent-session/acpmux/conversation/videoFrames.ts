// A look at a video's frames, as the transcript draws it (VideoFramesCard.tsx): the frames with the
// time of each, the video's name and length, instead of a tool row's raw output (Leo, 2026-11-01,
// after an agent's look at an attached video drew as a Shell card holding a long ffmpeg command with
// the Chat Uploads path printed twice, then a Read of a contact sheet: "i feel like cmux-next should
// give u better tools to deal with this kind of thing"). The source is the cmux agent tool
// `video_frames`: one image block per frame, plus a text block naming the video, its length and
// size and the time of each frame. The text is read loosely (a `key: value` note, a numbered list of
// frames, or the same facts as JSON), so a wording change in the tool never drops the card; a call
// whose frames cannot be found draws as any other tool row. Parsed once per tool snapshot
// (a WeakMap on the immutable call), never per render or per streamed token.
import type { AcpmuxActivity } from "../model";
import { mcpCall } from "./mcpCalls";
import { parseJSONValue } from "./toolResult";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

export type VideoFrame = {
  /// The frame as a `data:` URL (an ACP or MCP image block).
  src: string;
  /// Its time in the video, when the tool said it.
  atMs?: number;
};

export type VideoFrames = {
  /// The video's file, when the call or its note named one.
  path?: string;
  /// What the card calls the video: its file name, else "video".
  name?: string;
  durationMs?: number;
  width?: number;
  height?: number;
  frames: VideoFrame[];
  /// The note's text without the frames, for the opened row.
  text: string;
};

/// The most frames a card draws; a call with more keeps the first ones.
export const MAX_VIDEO_FRAMES = 32;
/// The largest frame drawn (its base64 text), as for any tool image (direct.ts).
const MAX_FRAME_CHARS = 8 * 1024 * 1024;
const VIDEO_PATH = /(?:^|[\s"'`(=:])(\/[^\s"'`()<>[\]]+\.(?:mov|mp4|m4v|webm|mkv|avi))(?![\w-])/i;
const KEYED_PATH = /^(?:video|file|path|source)\s*:\s*((?:\/|file:\/\/).+\.(?:mov|mp4|m4v|webm|mkv|avi))\s*$/i;
const TOOL_NAME =/(?:^|[._\s:/-])video[_-]?frames$/i;

/// Whether `tool` is a call of the `video_frames` tool (any MCP server's, by Claude Code's
/// `mcp__<server>__video_frames` or Codex's `{server, tool}`).
export function isVideoFramesCall(tool: Tool): boolean {
  const call = mcpCall(tool);
  return call !== undefined && TOOL_NAME.test(call.tool);
}

const cache = new WeakMap<Tool, VideoFrames | null>();

/// The video and frames a finished `video_frames` call returned, or undefined for any other call,
/// a running one, a failed one, or one with no frame.
export function videoFrames(tool: Tool): VideoFrames | undefined {
  const known = cache.get(tool);
  if (known !== undefined) return known ?? undefined;
  const parsed = parse(tool);
  cache.set(tool, parsed ?? null);
  return parsed;
}

function parse(tool: Tool): VideoFrames | undefined {
  if (tool.status !== "completed" || !isVideoFramesCall(tool)) return undefined;
  const { images, texts } = blocks(tool.output);
  const sources = dedupe([...(tool.images ?? []), ...images]).slice(0, MAX_VIDEO_FRAMES);
  if (sources.length === 0) return undefined;
  const text = texts.join("\n\n").trim();
  const facts = readFacts(text);
  const args = mcpCall(tool)?.args;
  const path = argPath(args) ?? facts.path;
  const frames = sources.map((src, index) => {
    const atMs = facts.times[index];
    return atMs === undefined ? { src } : { src, atMs };
  });
  return {
    ...(path ? { path, name: baseName(path) } : facts.name ? { name: facts.name } : {}),
    ...(facts.durationMs !== undefined ? { durationMs: facts.durationMs } : {}),
    ...(facts.width && facts.height ? { width: facts.width, height: facts.height } : {}),
    frames,
    text,
  };
}

const dedupe = (values: string[]) => [...new Set(values)];

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

/// The image and text blocks of an MCP or ACP result, unwrapped from `{content: [...]}`, a bare
/// list, ACP's `{type: "content", content}` and a JSON-RPC `result`; plain text is one text block.
function blocks(output: string | undefined): { images: string[]; texts: string[] } {
  const images: string[] = [];
  const texts: string[] = [];
  const value = parseJSONValue(output);
  const visit = (node: unknown, depth: number): boolean => {
    if (depth > 6) return false;
    if (Array.isArray(node)) {
      let any = false;
      for (const entry of node) any = visit(entry, depth + 1) || any;
      return any;
    }
    if (!isRecord(node)) return false;
    if (node.type === "content") return visit(node.content, depth + 1);
    if (node.type === "text" && typeof node.text === "string") {
      texts.push(node.text);
      return true;
    }
    if (node.type === "image" && typeof node.data === "string" && typeof node.mimeType === "string") {
      if (/^image\/(png|jpeg|gif|webp)$/.test(node.mimeType) && node.data.length <= MAX_FRAME_CHARS)
        images.push(`data:${node.mimeType};base64,${node.data}`);
      return true;
    }
    if (Array.isArray(node.content)) return visit(node.content, depth + 1);
    if (isRecord(node.result) || Array.isArray(node.result)) return visit(node.result, depth + 1);
    return false;
  };
  if (value === undefined || !visit(value, 0)) {
    if (output?.trim()) texts.push(output);
  }
  return { images, texts };
}

function argPath(args: unknown): string | undefined {
  if (!isRecord(args)) return undefined;
  for (const key of ["path", "file", "file_path", "video", "src", "source"]) {
    const value = args[key];
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return undefined;
}

/// A file name from a path or a `file://` URL.
export function baseName(path: string): string {
  const clean = path.replace(/^file:\/\//, "").replace(/[/\\]+$/, "");
  const name = clean.split(/[/\\]/).pop() ?? clean;
  try {
    return decodeURIComponent(name);
  } catch {
    return name;
  }
}

type Facts = {
  path?: string;
  name?: string;
  durationMs?: number;
  width?: number;
  height?: number;
  times: (number | undefined)[];
};

/// A time as a tool writes it: `1:02.5`, `00:01:02.500`, `62.5s`, `62500ms`, `62.5` (seconds).
export function parseTime(token: string): number | undefined {
  const text = token.trim().toLowerCase();
  const clock = /^(\d+):(\d{1,2})(?::(\d{1,2}))?(?:\.(\d+))?$/.exec(text);
  if (clock) {
    const [, a, b, c, fraction] = clock;
    const [h, m, s] = c === undefined ? [0, Number(a), Number(b)] : [Number(a), Number(b), Number(c)];
    const ms = fraction ? Number(`0.${fraction}`) * 1000 : 0;
    return Math.round((h * 3600 + m * 60 + s) * 1000 + ms);
  }
  const unit = /^(\d+(?:\.\d+)?)\s*(ms|s|sec|secs|seconds?)?$/.exec(text);
  if (!unit) return undefined;
  const value = Number(unit[1]);
  return Math.round(unit[2] === "ms" ? value : value * 1000);
}

const TIME = /(\d+:\d{1,2}(?::\d{1,2})?(?:\.\d+)?|\d+(?:\.\d+)?\s*(?:ms|s|sec|secs|seconds?)\b)/i;

function numberAt(record: Record<string, unknown>, keys: string[]): number | undefined {
  for (const key of keys) {
    const value = record[key];
    if (typeof value === "number" && Number.isFinite(value) && value >= 0) return value;
    if (typeof value === "string") {
      const time = parseTime(value);
      if (time !== undefined) return time;
    }
  }
  return undefined;
}

/// A time field of a JSON note: `atMs` / `durationMs` in ms, `at` / `time` / `duration` in seconds
/// when a number, as written when a string.
function jsonTime(record: Record<string, unknown>, msKeys: string[], secondKeys: string[]): number | undefined {
  const ms = numberAt(record, msKeys);
  if (ms !== undefined) return Math.round(ms);
  for (const key of secondKeys) {
    const value = record[key];
    if (typeof value === "number" && Number.isFinite(value) && value >= 0) return Math.round(value * 1000);
    if (typeof value === "string") {
      const time = parseTime(value);
      if (time !== undefined) return time;
    }
  }
  return undefined;
}

function readFacts(text: string): Facts {
  const json = parseJSONValue(text);
  if (isRecord(json)) return jsonFacts(json);
  const facts: Facts = { times: [] };
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) continue;
    const lower = line.toLowerCase();
    // "Video: /path/with spaces/clip.mp4" names the whole line's path, spaces and all (Chat Uploads).
    const named = facts.path ? undefined : KEYED_PATH.exec(line);
    if (named) facts.path = named[1]!.trim();
    if (facts.durationMs === undefined && /\b(duration|length)\b/.test(lower)) {
      const after = line.slice(lower.search(/\b(duration|length)\b/));
      const time = TIME.exec(after);
      if (time) facts.durationMs = parseTime(time[1]!);
    }
    if (facts.width === undefined) {
      const size = /\b(\d{2,5})\s*[x×]\s*(\d{2,5})\b/.exec(line);
      if (size) {
        facts.width = Number(size[1]);
        facts.height = Number(size[2]);
      }
    }
    // A frame's line: "frame 3 at 0:04.0", "#3 0:04.0", "3. 0:04.0", "- 0:04.0".
    const frame = /^(?:[-*•]\s*)?(?:frame\s*#?\s*\d+\b|#\d+\b|\d+[.)])\s*[:\-–—@]?\s*(?:at\s+|t\s*=\s*)?(.*)$/i.exec(line);
    const bullet = !frame && /^[-*•]\s+(?:at\s+|t\s*=\s*)?(.*)$/i.exec(line);
    const rest = frame?.[1] ?? (bullet ? bullet[1] : undefined);
    if (rest !== undefined && !/\b(duration|length)\b/.test(lower)) {
      const time = TIME.exec(rest);
      if (time) facts.times.push(parseTime(time[1]!));
    }
  }
  if (!facts.path) {
    const path = VIDEO_PATH.exec(text);
    if (path) facts.path = path[1];
  }
  return facts;
}

function jsonFacts(json: Record<string, unknown>): Facts {
  const facts: Facts = { times: [] };
  for (const key of ["path", "file", "video", "source"]) {
    if (typeof json[key] === "string") {
      facts.path = json[key] as string;
      break;
    }
  }
  if (!facts.path && typeof json.name === "string") facts.name = json.name;
  const duration = jsonTime(json, ["durationMs", "duration_ms"], ["duration", "durationSeconds", "length"]);
  if (duration !== undefined) facts.durationMs = duration;
  const width = numberAt(json, ["width"]);
  const height = numberAt(json, ["height"]);
  if (width && height) {
    facts.width = Math.round(width);
    facts.height = Math.round(height);
  } else if (typeof json.size === "string") {
    const size = /(\d{2,5})\s*[x×]\s*(\d{2,5})/.exec(json.size);
    if (size) {
      facts.width = Number(size[1]);
      facts.height = Number(size[2]);
    }
  }
  const frames = Array.isArray(json.frames) ? json.frames : Array.isArray(json.timestamps) ? json.timestamps : [];
  for (const frame of frames) {
    if (typeof frame === "number") facts.times.push(Math.round(frame * 1000));
    else if (typeof frame === "string") facts.times.push(parseTime(frame));
    else if (isRecord(frame))
      facts.times.push(jsonTime(frame, ["atMs", "at_ms", "timeMs", "timestampMs"], ["at", "time", "timestamp", "t"]));
    else facts.times.push(undefined);
  }
  return facts;
}

/// A frame's time as its badge says it: `m:ss`, `h:mm:ss`, with tenths under a minute's video
/// when two frames would otherwise read the same.
export function frameLabel(ms: number, tenths: boolean): string {
  const total = Math.max(0, ms) / 1000;
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const seconds = tenths ? (Math.floor(s * 10) / 10).toFixed(1).padStart(4, "0") : String(Math.floor(s)).padStart(2, "0");
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${seconds}` : `${m}:${seconds}`;
}

/// Whether whole seconds would show two of `frames` with the same time.
export function needsTenths(frames: readonly VideoFrame[]): boolean {
  const seen = new Set<number>();
  for (const frame of frames) {
    if (frame.atMs === undefined) continue;
    const second = Math.floor(frame.atMs / 1000);
    if (seen.has(second)) return true;
    seen.add(second);
  }
  return false;
}
