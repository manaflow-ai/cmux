import { fileName, fileStats, gitStatusType, type DiffItem } from "./diff-stream";

export type MobileDiffThemeMode = "light" | "dark";

export type MobileDiffFileStats = {
  path: string;
  oldPath?: string;
  status: string;
  additions: number;
  deletions: number;
  binary?: true;
};

export type MobileDiffStatsMessage = {
  type: "stats";
  files: MobileDiffFileStats[];
  totalAdditions: number;
  totalDeletions: number;
};

export type MobileDiffCurrentFileMessage = {
  type: "currentFile";
  path: string;
  index: number;
  total: number;
};

export type MobileDiffMessage =
  | { type: "ready" }
  | MobileDiffStatsMessage
  | MobileDiffCurrentFileMessage
  | { type: "error"; message: string };

export function postMobileDiffMessage(message: MobileDiffMessage): void {
  (window as MobileDiffWindow).webkit?.messageHandlers?.cmuxMobileDiff?.postMessage(message);
}

type MobileDiffWindow = Window & {
  webkit?: {
    messageHandlers?: {
      cmuxMobileDiff?: {
        postMessage(message: unknown): void;
      };
    };
  };
};

export function mobileDiffStatsMessage(items: readonly DiffItem[]): MobileDiffStatsMessage {
  const files = items.map((item): MobileDiffFileStats => {
    const diff = item.fileDiff ?? {};
    const stats = fileStats(diff);
    const path = fileName(diff, item.id);
    const oldPath = typeof diff.prevName === "string" && diff.prevName !== "" && diff.prevName !== path
      ? diff.prevName
      : undefined;
    return {
      path,
      ...(oldPath ? { oldPath } : {}),
      status: gitStatusType(diff.type),
      additions: stats.added,
      deletions: stats.deleted,
      ...(isBinaryDiff(diff) ? { binary: true as const } : {}),
    };
  });
  return {
    type: "stats",
    files,
    totalAdditions: files.reduce((total, file) => total + file.additions, 0),
    totalDeletions: files.reduce((total, file) => total + file.deletions, 0),
  };
}

export function mobileDiffErrorMessage(error: unknown, fallback: string): string {
  if (error instanceof Error && error.message.trim() !== "") {
    return error.message;
  }
  return fallback;
}

export type ThrottledEmitter<T> = {
  dispose(): void;
  push(value: T): void;
};

type ThrottleClock = {
  clearTimeout(id: ReturnType<typeof setTimeout>): void;
  now(): number;
  setTimeout(callback: () => void, delay: number): ReturnType<typeof setTimeout>;
};

const defaultThrottleClock: ThrottleClock = {
  clearTimeout: (id) => clearTimeout(id),
  now: () => performance.now(),
  setTimeout: (callback, delay) => setTimeout(callback, delay),
};

/**
 * Emits immediately when idle, then coalesces a flick's intermediate file
 * boundaries into one trailing update. Equal updates are suppressed, including
 * a quick move away and back before native observed the intermediate file.
 */
export function createThrottledEmitter<T>(
  emit: (value: T) => void,
  intervalMs = 250,
  equals: (left: T, right: T) => boolean = Object.is,
  clock: ThrottleClock = defaultThrottleClock,
): ThrottledEmitter<T> {
  let disposed = false;
  let lastEmitted: T | undefined;
  let lastEmittedAt = Number.NEGATIVE_INFINITY;
  let pending: T | undefined;
  let timer: ReturnType<typeof setTimeout> | undefined;

  const flush = () => {
    timer = undefined;
    if (disposed || pending === undefined) {
      return;
    }
    const value = pending;
    pending = undefined;
    if (lastEmitted !== undefined && equals(lastEmitted, value)) {
      return;
    }
    lastEmitted = value;
    lastEmittedAt = clock.now();
    emit(value);
  };

  return {
    dispose() {
      disposed = true;
      pending = undefined;
      if (timer !== undefined) {
        clock.clearTimeout(timer);
        timer = undefined;
      }
    },
    push(value) {
      if (disposed) {
        return;
      }
      if (pending !== undefined && equals(pending, value)) {
        return;
      }
      if (pending === undefined && lastEmitted !== undefined && equals(lastEmitted, value)) {
        return;
      }
      const delay = Math.max(0, intervalMs - (clock.now() - lastEmittedAt));
      if (timer === undefined && delay === 0) {
        lastEmitted = value;
        lastEmittedAt = clock.now();
        emit(value);
        return;
      }
      pending = value;
      if (timer === undefined) {
        timer = clock.setTimeout(flush, delay);
      }
    },
  };
}

export function sameCurrentFileMessage(
  left: MobileDiffCurrentFileMessage,
  right: MobileDiffCurrentFileMessage,
): boolean {
  return left.path === right.path && left.index === right.index && left.total === right.total;
}

function isBinaryDiff(diff: any): boolean {
  return diff.binary === true || diff.isBinary === true || diff.cmuxBinary === true;
}
