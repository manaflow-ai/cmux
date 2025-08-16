import { promises as fs } from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

/**
 * Gemini session/message types (best-effort)
 * The Gemini CLI may log JSONL transcripts under a provider-specific location.
 * We mirror the Claude detector pattern and look for JSONL in a per-project folder.
 */
interface GeminiMessageLike {
  role?: string; // "user" | "assistant" | "model" | unknown
  content?: string;
  timestamp?: string;
  // Additional fields ignored
  [key: string]: unknown;
}

// Compute a project path we expect Gemini CLI to use for transcripts.
// This mirrors the Claude convention, using an encoded working dir.
export function getGeminiProjectPath(workingDir: string): string {
  const homeDir = os.homedir();
  const encoded = workingDir.replace(/\//g, "-");
  return path.join(homeDir, ".gemini", "projects", encoded);
}

async function getMostRecentJsonlFile(projectDir: string): Promise<string | null> {
  try {
    await fs.access(projectDir);
  } catch {
    return null;
  }
  try {
    const files = await fs.readdir(projectDir);
    const jsonlFiles = files.filter((f) => f.endsWith(".jsonl")).sort((a, b) => b.localeCompare(a));
    if (!jsonlFiles.length) return null;
    const first = jsonlFiles[0];
    if (!first) return null;
    return path.join(projectDir, first);
  } catch {
    return null;
  }
}

async function getLastMessage(filePath: string): Promise<GeminiMessageLike | null> {
  try {
    const content = await fs.readFile(filePath, "utf-8");
    const lines = content.split("\n").filter((l) => l.trim());
    if (!lines.length) return null;
    // Scan from end for a parseable JSON object
    for (let i = lines.length - 1; i >= 0; i--) {
      const line = lines[i] as string;
      try {
        const obj = JSON.parse(line) as GeminiMessageLike;
        // Try to normalize a couple of common shapes
        let role = obj.role;
        let content = obj.content;
        if (!content && typeof (obj as any).text === "string") content = (obj as any).text;
        return { ...obj, role, content };
      } catch {
        // continue scanning up
      }
    }
    return null;
  } catch {
    return null;
  }
}

/**
 * Heuristic completion detection for Gemini CLI transcripts.
 * Considered complete when:
 * - The most recent message is from the assistant/model, and
 * - The session has been idle for at least `minIdleTimeMs`, and
 * - Optionally, the last message includes a completion phrase.
 */
export async function checkGeminiProjectFileCompletion(
  projectPath?: string,
  workingDir?: string,
  minIdleTimeMs: number = 10000
): Promise<boolean> {
  const projectDir = projectPath || (workingDir ? getGeminiProjectPath(workingDir) : null);
  if (!projectDir) throw new Error("Either projectPath or workingDir must be provided");

  const jsonl = await getMostRecentJsonlFile(projectDir);
  if (!jsonl) return false;

  const last = await getLastMessage(jsonl);
  if (!last) return false;

  const role = (last.role || "").toLowerCase();
  const isAssistant = role === "assistant" || role === "model";
  if (!isAssistant) return false;

  // Idle check if timestamp available
  if (last.timestamp) {
    const ts = Date.parse(last.timestamp);
    if (!Number.isNaN(ts)) {
      const idle = Date.now() - ts;
      if (idle < minIdleTimeMs) return false;
    }
  }

  // Optional phrase check to increase confidence
  const phrases = [
    "task complete",
    "completed successfully",
    "i've completed",
    "i have completed",
    "all done",
    "finished",
    "implementation is complete",
    "ready for review",
  ];
  const content = (last.content || "").toLowerCase();
  const hasPhrase = phrases.some((p) => content.includes(p));

  // Accept completion if assistant/model with idle; phrase is a bonus (not strictly required)
  return true && (hasPhrase || true);
}

export interface GeminiCompletionMonitorOptions {
  workingDir: string;
  checkIntervalMs?: number;
  maxRuntimeMs?: number;
  minRuntimeMs?: number;
  onComplete?: () => void | Promise<void>;
  onError?: (error: Error) => void;
}

export function monitorGeminiCompletion(
  options: GeminiCompletionMonitorOptions
): () => void {
  const {
    workingDir,
    checkIntervalMs = 5000,
    maxRuntimeMs = 20 * 60 * 1000,
    minRuntimeMs = 30000,
    onComplete,
    onError,
  } = options;

  const start = Date.now();
  const projectDir = getGeminiProjectPath(workingDir);
  let intervalId: NodeJS.Timeout | null = null;
  let stopped = false;

  const tick = async () => {
    if (stopped) return;
    try {
      const elapsed = Date.now() - start;
      if (elapsed < minRuntimeMs) return;
      if (elapsed > maxRuntimeMs) {
        stop();
        if (onError) onError(new Error(`Gemini session exceeded max runtime of ${maxRuntimeMs}ms`));
        return;
      }
      const isComplete = await checkGeminiProjectFileCompletion(projectDir, undefined, 10000);
      if (isComplete) {
        stop();
        if (onComplete) await onComplete();
      }
    } catch (err) {
      if (onError) onError(err instanceof Error ? err : new Error(String(err)));
    }
  };

  intervalId = setInterval(tick, checkIntervalMs);
  setTimeout(tick, minRuntimeMs);

  const stop = () => {
    stopped = true;
    if (intervalId) clearInterval(intervalId);
    intervalId = null;
  };
  return stop;
}

export default {
  getGeminiProjectPath,
  checkGeminiProjectFileCompletion,
  monitorGeminiCompletion,
};

