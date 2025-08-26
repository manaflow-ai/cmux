import { promises as fsp } from "node:fs";
import { watch, createReadStream, type FSWatcher } from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

type StopFn = () => void;

function getOpencodeLogDirs(): string[] {
  const home = os.homedir();
  return [
    path.join(home, ".local", "share", "opencode", "log"),
    path.join(home, ".config", "opencode", "log"),
    path.join(home, ".opencode", "log"),
  ];
}

function isIdleEvent(line: string): boolean {
  const trimmed = line.trim();
  if (!trimmed) return false;
  // Fast substring check first
  if (/session\.idle/i.test(trimmed)) return true;
  // Try parse JSON if it looks like JSON
  if (trimmed.startsWith("{") || trimmed.startsWith("[")) {
    try {
      const obj = JSON.parse(trimmed) as any;
      const event = obj.event || obj.payload || obj;
      const type = String(event?.type || event?.Type || "").toLowerCase();
      if (type === "session.idle" || type.endsWith("session.idle")) return true;
    } catch {
      // ignore
    }
  }
  // Also match common key=value formats
  if (/type\s*=\s*session\.idle/i.test(trimmed)) return true;
  return false;
}

/**
 * Watch OpenCode log files for a session.idle event and invoke onComplete immediately.
 * - Watches known log directories under the user home directory
 * - Attaches file watchers to existing .log files and streams appended bytes
 * - Also watches the directory to attach to newly created log files
 */
export function watchOpencodeLogsForCompletion(options: {
  sinceMs?: number; // optional lower bound on event time (best-effort)
  onComplete: () => void | Promise<void>;
  onError?: (error: Error) => void;
}): StopFn {
  const { sinceMs = 0, onComplete, onError } = options;
  let stopped = false;
  const dirWatchers: FSWatcher[] = [];
  const fileWatchers: Map<string, FSWatcher> = new Map();
  const lastSizes: Map<string, number> = new Map();

  // Simple line splitter for appended text chunks
  const buffers: Map<string, string> = new Map();
  const feed = (file: string, chunk: string) => {
    const prev = buffers.get(file) || "";
    const data = prev + chunk;
    const lines = data.split(/\r?\n/);
    buffers.set(file, lines.pop() || "");
    for (const line of lines) {
      try {
        if (isIdleEvent(line)) {
          // Optional crude timestamp gate: if the line contains ISO-like ts and is older than sinceMs, ignore
          const match = line.match(/(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})/);
          if (match && match[1]) {
            const ts = Date.parse(match[1]);
            if (!Number.isNaN(ts) && ts < sinceMs) continue;
          }
          if (!stopped) {
            stopped = true;
            stop();
            Promise.resolve(onComplete()).catch((e) =>
              onError?.(e instanceof Error ? e : new Error(String(e)))
            );
            return;
          }
        }
      } catch (e) {
        onError?.(e instanceof Error ? e : new Error(String(e)));
      }
    }
  };

  const attachFileWatcher = async (filePath: string) => {
    if (stopped || fileWatchers.has(filePath)) return;
    try {
      const st = await fsp.stat(filePath);
      lastSizes.set(filePath, st.size);
    } catch {
      lastSizes.set(filePath, 0);
    }

    const readNew = async (initial = false) => {
      try {
        const st = await fsp.stat(filePath);
        const start = initial ? 0 : lastSizes.get(filePath) || 0;
        if (st.size <= start) {
          lastSizes.set(filePath, st.size);
          return;
        }
        await new Promise<void>((resolve) => {
          const rs = createReadStream(filePath, {
            start,
            end: st.size - 1,
            encoding: "utf-8",
          });
          rs.on("data", (chunk: string | Buffer) => {
            const text = typeof chunk === "string" ? chunk : chunk.toString("utf-8");
            feed(filePath, text);
          });
          rs.on("end", resolve);
          rs.on("error", resolve);
        });
        lastSizes.set(filePath, st.size);
      } catch (e) {
        // ignore transient errors
      }
    };

    // Initial read of existing content (helpful if the event already happened)
    await readNew(true);

    const fw = watch(filePath, { persistent: false }, async (evt) => {
      if (stopped) return;
      if (evt === "change") await readNew(false);
    });
    fileWatchers.set(filePath, fw);
  };

  const attachDirWatcher = async (dir: string) => {
    try {
      await fsp.mkdir(dir, { recursive: true });
    } catch {}
    try {
      const files = await fsp.readdir(dir);
      for (const f of files) {
        if (f.endsWith(".log")) await attachFileWatcher(path.join(dir, f));
      }
    } catch {}

    const dw = watch(
      dir,
      { persistent: false },
      async (_evt, filename) => {
        if (stopped) return;
        const name = filename?.toString();
        if (!name) return;
        if (name.endsWith(".log")) {
          await attachFileWatcher(path.join(dir, name));
        }
      }
    );
    dirWatchers.push(dw);
  };

  for (const dir of getOpencodeLogDirs()) {
    void attachDirWatcher(dir);
  }

  const stop = () => {
    for (const w of dirWatchers) {
      try {
        w.close();
      } catch {}
    }
    dirWatchers.splice(0, dirWatchers.length);
    for (const [, w] of fileWatchers) {
      try {
        w.close();
      } catch {}
    }
    fileWatchers.clear();
  };

  return stop;
}

export default {
  watchOpencodeLogsForCompletion,
};

