// Which chat, turn, model and prompt wrote a changed line (acpmux `_acpmux/attribution`). A chat's
// edit diff asks for the added lines it shows once someone hovers it, and a marker on a hovered
// line names its writers. The answers are kept per file at one git head; a line asked once is never
// asked again for that head, and the store holds a bounded number of files.
import type { TurnFile } from "../diff";

/// The daemon capability that serves `_acpmux/attribution`; an older daemon lacks it and is never asked.
export const ATTRIBUTION_CAPABILITY = "attribution-v1";
/// The most ranges one request may name (acpmux refuses more).
export const MAX_ATTRIBUTION_RANGES = 64;
/// The most files whose answers the store keeps; the oldest goes first.
export const MAX_ATTRIBUTION_FILES = 64;
/// The most requests out at once.
export const MAX_ATTRIBUTION_IN_FLIGHT = 2;
/// The most answers one file keeps, so a file with many writers stays bounded.
const MAX_FILE_ATTRIBUTIONS = 512;

/// One turn's lines in a file: `start` to `end` (1-based, inclusive) of the file at the asked head.
export type Attribution = {
  start: number;
  end: number;
  sessionId: string;
  turnId: string;
  model?: string;
  /// The chat's title.
  title?: string;
  /// The first line of the turn's prompt.
  prompt?: string;
  /// When the turn ended, in Unix ms.
  at: number;
};

/// A file of a repository at one commit: `root` is the absolute top level, `path` relative to it.
export type AttributionTarget = { root: string; head: string; path: string };

/// The repository a chat's folder is in, at its current commit.
export type AttributionRepo = { root: string; head: string };

/// Inclusive 1-based line ranges, as the request names them.
export type LineRange = [number, number];

/// The request's params (acpmux `_acpmux/attribution`). `texts`, beside `ranges`, are the lines the
/// diff shows there: acpmux answers a range only while the file holds those lines, so an older
/// turn's diff never names whoever rewrote its lines since.
export type AttributionParams = AttributionTarget & { ranges: LineRange[]; texts?: string[][] };

const text = (value: unknown) => (typeof value === "string" && value ? value : undefined);
const line = (value: unknown) =>
  typeof value === "number" && Number.isInteger(value) && value >= 1 ? value : undefined;

/// The answer's attributions, each checked; an entry with a bad field is dropped, never guessed.
export function parseAttributions(value: unknown): Attribution[] {
  const list = (value as { attributions?: unknown } | null | undefined)?.attributions;
  if (!Array.isArray(list)) return [];
  const out: Attribution[] = [];
  for (const entry of list) {
    if (!entry || typeof entry !== "object") continue;
    const raw = entry as Record<string, unknown>;
    const start = line(raw.start);
    const end = line(raw.end);
    const sessionId = text(raw.sessionId);
    const turnId = text(raw.turnId);
    const at = typeof raw.at === "number" && Number.isFinite(raw.at) ? raw.at : undefined;
    if (start === undefined || end === undefined || end < start || !sessionId || !turnId || at === undefined) continue;
    const model = text(raw.model);
    const title = text(raw.title);
    const prompt = text(raw.prompt);
    out.push({
      start,
      end,
      sessionId,
      turnId,
      at,
      ...(model ? { model } : {}),
      ...(title ? { title } : {}),
      ...(prompt ? { prompt } : {}),
    });
  }
  return out;
}

/// The turns that wrote `lineNumber` among `attributions`: one per turn, newest first.
export function writersOf(attributions: readonly Attribution[], lineNumber: number): Attribution[] {
  const seen = new Set<string>();
  const out: Attribution[] = [];
  for (const entry of attributions) {
    if (lineNumber < entry.start || lineNumber > entry.end) continue;
    const key = `${entry.sessionId}\0${entry.turnId}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(entry);
  }
  return out.sort((a, b) => b.at - a.at);
}

/// The new-file line numbers of the lines `file`'s numbered edits add, ascending and unique. A
/// fragment edit has no known place in its file, so it adds none.
export function addedLines(file: TurnFile): number[] {
  const lines = new Set<number>();
  for (const edit of file.edits) {
    if (!edit.numbered) continue;
    for (const hunk of edit.hunks)
      for (const each of hunk.lines) if (each.type === "add" && each.newLine !== undefined) lines.add(each.newLine);
  }
  return [...lines].sort((a, b) => a - b);
}

/// The text each added line of `file`'s numbered edits shows, by new-file line number; a line two
/// edits add keeps the later edit's text.
export function addedTexts(file: TurnFile): Map<number, string> {
  const texts = new Map<number, string>();
  for (const edit of file.edits) {
    if (!edit.numbered) continue;
    for (const hunk of edit.hunks)
      for (const each of hunk.lines)
        if (each.type === "add" && each.newLine !== undefined) texts.set(each.newLine, each.text);
  }
  return texts;
}

/// `lines` (ascending) merged into ranges of consecutive lines, the first `cap` of them.
export function lineRanges(lines: readonly number[], cap = MAX_ATTRIBUTION_RANGES): LineRange[] {
  const ranges: LineRange[] = [];
  for (const each of lines) {
    const last = ranges[ranges.length - 1];
    if (last && each <= last[1] + 1) last[1] = Math.max(last[1], each);
    else if (ranges.length === cap) break;
    else ranges.push([each, each]);
  }
  return ranges;
}

/// The ranges to ask for `file`'s added lines.
export function addedRanges(file: TurnFile, cap = MAX_ATTRIBUTION_RANGES): LineRange[] {
  return lineRanges(addedLines(file), cap);
}

/// The file `canonical` names inside `repo`, or undefined for a path outside it.
export function targetOf(
  canonical: string | undefined,
  repo: AttributionRepo | undefined,
): AttributionTarget | undefined {
  if (!canonical || !repo?.root || !repo.head) return undefined;
  const root = repo.root.replace(/\/+$/, "");
  if (!canonical.startsWith(`${root}/`)) return undefined;
  const path = canonical.slice(root.length + 1);
  if (!path || path.split("/").some((part) => !part || part === "." || part === "..")) return undefined;
  return { root, head: repo.head, path };
}

/// The store's key of a file at one head.
export const attributionKey = (target: AttributionTarget) => `${target.root}\0${target.head}\0${target.path}`;

/// Each asked line with the text it was asked with, and the answers.
type FileAnswers = { asked: Map<number, string | undefined>; attributions: Attribution[] };
type Job = {
  target: AttributionTarget;
  key: string;
  ranges: LineRange[];
  texts: ReadonlyMap<number, string> | undefined;
};

/// The answers per file at one head, and the requests that fill them: at most
/// `MAX_ATTRIBUTION_IN_FLIGHT` out at once, and a newer want replaces the ones still queued.
export class AttributionStore {
  private readonly files = new Map<string, FileAnswers>();
  private readonly listeners = new Set<() => void>();
  private queued: Job | undefined;
  private inFlight = 0;
  private generation = 0;
  /// Bumps on every change a reader can see.
  version = 0;

  constructor(
    private readonly ask: (params: AttributionParams) => Promise<unknown>,
    private readonly maxFiles = MAX_ATTRIBUTION_FILES,
    private readonly maxInFlight = MAX_ATTRIBUTION_IN_FLIGHT,
  ) {}

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  };

  getVersion = () => this.version;

  /// The turns that wrote `lineNumber` of `target` showing `text`, newest first; none before its
  /// answer came, and none for a line last asked with other text.
  writersOf(target: AttributionTarget, lineNumber: number, text?: string): Attribution[] {
    const file = this.files.get(attributionKey(target));
    if (!file?.asked.has(lineNumber) || file.asked.get(lineNumber) !== text) return [];
    return writersOf(file.attributions, lineNumber);
  }

  /// Bumps when `forget` drops every answer.
  get epoch(): number {
    return this.generation;
  }

  /// Asks for `lines` of `target` (showing `texts`) that were never asked at this head with that
  /// text, the first `MAX_ATTRIBUTION_RANGES` ranges of them. True when that left none unasked or
  /// queued.
  want(target: AttributionTarget, lines: readonly number[], texts?: ReadonlyMap<number, string>): boolean {
    const key = attributionKey(target);
    const asked = this.files.get(key)?.asked;
    const left = asked ? lines.filter((each) => !asked.has(each) || asked.get(each) !== texts?.get(each)) : lines;
    const ranges = lineRanges(left);
    if (!ranges.length) return true;
    const job = { target, key, ranges, texts };
    // A queued want may yet be replaced by a newer one, so its lines count as unasked.
    if (this.inFlight >= this.maxInFlight) {
      this.queued = job;
      return false;
    }
    this.send(job);
    return left[left.length - 1]! <= ranges[ranges.length - 1]![1];
  }

  /// Drops every answer: the files may have changed since (a turn ended).
  forget(): void {
    this.generation++;
    this.queued = undefined;
    // A chat replaying its turns ends many: with nothing kept, no reader hears of it.
    if (!this.files.size) return;
    this.files.clear();
    this.changed();
  }

  private file(key: string): FileAnswers {
    let file = this.files.get(key);
    if (file) {
      // The newest used file goes last, so the oldest is first out.
      this.files.delete(key);
    } else {
      file = { asked: new Map(), attributions: [] };
      while (this.files.size >= this.maxFiles) this.files.delete(this.files.keys().next().value!);
    }
    this.files.set(key, file);
    return file;
  }

  private send(job: Job): void {
    const file = this.file(job.key);
    // A line asked again with other text: its earlier answers named the other text's writers.
    const again = (start: number, end: number) => job.ranges.some(([from, to]) => from <= end && start <= to);
    file.attributions = file.attributions.filter((entry) => !again(entry.start, entry.end));
    for (const [start, end] of job.ranges)
      for (let each = start; each <= end; each++) file.asked.set(each, job.texts?.get(each));
    const generation = this.generation;
    this.inFlight++;
    const done = (value: unknown) => {
      this.inFlight--;
      // An answer whose lines were asked again since, with other text, names the other text's writers.
      const current = job.ranges.every(([start, end]) => {
        for (let each = start; each <= end; each++) if (file.asked.get(each) !== job.texts?.get(each)) return false;
        return true;
      });
      if (generation === this.generation && this.files.get(job.key) === file && current) {
        const answers = parseAttributions(value);
        if (answers.length) {
          // The newest are kept: an answer comes newest first, and so is the merged list.
          file.attributions = [...answers, ...file.attributions]
            .sort((a, b) => b.at - a.at)
            .slice(0, MAX_FILE_ATTRIBUTIONS);
          this.changed();
        }
      }
      const next = this.queued;
      this.queued = undefined;
      if (next) this.want(next.target, rangeLines(next.ranges), next.texts);
    };
    let asked: Promise<unknown>;
    try {
      const texts = job.texts;
      asked = this.ask({
        ...job.target,
        ranges: job.ranges,
        ...(texts
          ? { texts: job.ranges.map(([start, end]) => rangeLines([[start, end]]).map((each) => texts.get(each) ?? "")) }
          : {}),
      });
    } catch (error) {
      asked = Promise.reject(error);
    }
    // A refusal (a remote chat, a busy daemon) shows nothing; the lines stay asked.
    asked.then(done, () => done(undefined));
  }

  private changed(): void {
    this.version++;
    for (const listener of this.listeners) listener();
  }
}

/// Every line of `ranges`.
function rangeLines(ranges: readonly LineRange[]): number[] {
  const out: number[] = [];
  for (const [start, end] of ranges) for (let each = start; each <= end; each++) out.push(each);
  return out;
}
