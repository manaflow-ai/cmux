import { watch, type FSWatcher } from "node:fs";
import { promises as fs } from "node:fs";
import * as path from "node:path";

export type CursorDetectorHandle = { stop: () => void };

/**
 * Watches the Cursor Agent stream-json NDJSON file and triggers completion
 * when a terminal result event is observed: { type: "result", subtype: "success" }
 */
export async function createCursorDetector(options: {
  taskRunId: string;
  startTime: number;
  onComplete: (data: {
    taskRunId: string;
    elapsedMs: number;
    detectionMethod: string;
  }) => void;
  onError?: (error: Error) => void;
}): Promise<CursorDetectorHandle> {
  const file = `/root/lifecycle/cursor-stream-${options.taskRunId}.ndjson`;
  const dir = path.dirname(file);

  let stopped = false;
  let dirWatcher: FSWatcher | null = null;
  let fileWatcher: FSWatcher | null = null;
  let lastSize = 0;
  let remainder = "";

  const stop = () => {
    if (stopped) return;
    stopped = true;
    try { fileWatcher?.close(); } catch {}
    try { dirWatcher?.close(); } catch {}
  };

  const handleComplete = () => {
    if (stopped) return;
    stopped = true;
    try { fileWatcher?.close(); } catch {}
    try { dirWatcher?.close(); } catch {}
    const elapsedMs = Date.now() - options.startTime;
    try {
      options.onComplete({
        taskRunId: options.taskRunId,
        elapsedMs,
        detectionMethod: "cursor-stream-json",
      });
    } catch (err) {
      options.onError?.(err instanceof Error ? err : new Error(String(err)));
    }
  };

  const parseLines = (text: string) => {
    const combined = remainder + text;
    const lines = combined.split(/\r?\n/);
    remainder = lines.pop() || ""; // keep last partial line
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      try {
        const obj = JSON.parse(trimmed) as any;
        if (
          obj &&
          typeof obj === "object" &&
          obj.type === "result" &&
          obj.subtype === "success" &&
          obj.is_error === false
        ) {
          handleComplete();
          return; // stop parsing further
        }
      } catch {
        // ignore malformed line
      }
    }
  };

  const readNew = async (initial = false) => {
    try {
      const st = await fs.stat(file);
      const start = initial ? 0 : lastSize;
      if (st.size <= start) {
        lastSize = st.size;
        return;
      }
      const end = st.size - 1;
      const fh = await fs.open(file, "r");
      try {
        const buf = Buffer.alloc(end - start + 1);
        await fh.read(buf, 0, buf.length, start);
        parseLines(buf.toString("utf-8"));
      } finally {
        await fh.close();
      }
      lastSize = st.size;
    } catch {
      // file may not exist yet
    }
  };

  const attachFileWatcher = async () => {
    try {
      const st = await fs.stat(file);
      lastSize = st.size;
      await readNew(true);
      fileWatcher = watch(file, { persistent: false }, async (eventType) => {
        if (!stopped && eventType === "change") {
          await readNew(false);
        }
      });
    } catch {
      // not created yet
    }
  };

  // watch directory for file creation, then attach file watcher
  dirWatcher = watch(dir, { persistent: false }, async (_event, name) => {
    if (stopped) return;
    if (name?.toString() === path.basename(file)) {
      await attachFileWatcher();
    }
  });

  // Also try immediately if file already exists
  await attachFileWatcher();

  return { stop };
}

