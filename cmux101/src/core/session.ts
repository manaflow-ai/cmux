/**
 * Session: manages a cmux101 agent session on disk.
 * Sessions live under ~/.cmux101/sessions/<id>/ (user scope)
 * or <cwd>/.cmux101/sessions/<id>/ (project scope).
 */

import { existsSync, mkdirSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import type { Message, SessionHandle, SessionMeta } from "./types.js";
import { Transcript } from "./transcript.js";

// ----------------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------------

function userSessionsRoot(home?: string): string {
  return join(home ?? homedir(), ".cmux101", "sessions");
}

function projectSessionsRoot(cwd: string): string {
  return join(cwd, ".cmux101", "sessions");
}

/** @deprecated Use userSessionsRoot instead. Kept for backward compat. */
function sessionsRoot(home?: string): string {
  return userSessionsRoot(home);
}

function sessionDir(sessionId: string, home?: string): string {
  return join(userSessionsRoot(home), sessionId);
}

function projectSessionDir(sessionId: string, cwd: string): string {
  return join(projectSessionsRoot(cwd), sessionId);
}

// ----------------------------------------------------------------------------
// Session class
// ----------------------------------------------------------------------------

export class Session implements SessionHandle {
  readonly meta: SessionMeta;
  private _messages: Message[];
  private _transcript: Transcript;

  constructor(meta: SessionMeta, messages: Message[], transcript: Transcript) {
    this.meta = meta;
    this._messages = messages;
    this._transcript = transcript;
  }

  get messages(): ReadonlyArray<Message> {
    return this._messages;
  }

  async append(message: Message): Promise<void> {
    this._messages.push(message);
    await this._transcript.append({
      kind: "message",
      message,
      ts: new Date().toISOString(),
    });
  }

  async recordEvent(event: { kind: string; data: unknown }): Promise<void> {
    await this._transcript.append({
      kind: "custom",
      name: event.kind,
      data: event.data,
      ts: new Date().toISOString(),
    });
  }

  /** Expose transcript path for tests and subagent results. */
  get transcriptPath(): string {
    return this._transcript.path;
  }
}

// ----------------------------------------------------------------------------
// createSession
// ----------------------------------------------------------------------------

export async function createSession(options: {
  cwd: string;
  providerId: string;
  model: string;
  system?: string;
  /** Override home dir (used in tests). */
  home?: string;
  /**
   * Storage scope for this session.
   * - "user" (default): ~/.cmux101/sessions/<id>/
   * - "project":        <cwd>/.cmux101/sessions/<id>/
   */
  scope?: "user" | "project";
  /** Worker ID to embed in worker_state.json. Defaults to a new UUID. */
  workerId?: string;
  /** Permission mode to embed in worker_state.json. */
  permissionMode?: "default" | "read-only" | "workspace-write" | "danger-full-access";
}): Promise<Session> {
  const id = crypto.randomUUID();
  const scope = options.scope ?? "user";
  const dir =
    scope === "project"
      ? projectSessionDir(id, options.cwd)
      : sessionDir(id, options.home);
  mkdirSync(dir, { recursive: true });

  const meta: SessionMeta = {
    id,
    cwd: options.cwd,
    startedAt: new Date().toISOString(),
    providerId: options.providerId,
    model: options.model,
    system: options.system,
  };

  // Write meta.json
  await Bun.write(join(dir, "meta.json"), JSON.stringify(meta, null, 2));

  // Create transcript and write session_start event
  const transcript = new Transcript(join(dir, "transcript.jsonl"));
  await transcript.append({ kind: "session_start", meta, ts: new Date().toISOString() });

  // Write worker_state.json to <cwd>/.cmux101/worker_state.json (best-effort).
  try {
    const workerStateDir = join(options.cwd, ".cmux101");
    mkdirSync(workerStateDir, { recursive: true });
    const workerState = {
      workerId: options.workerId ?? crypto.randomUUID(),
      sessionId: id,
      providerId: options.providerId,
      model: options.model,
      permissionMode: options.permissionMode ?? "default",
      startedAt: meta.startedAt,
      cwd: options.cwd,
    };
    await Bun.write(
      join(workerStateDir, "worker_state.json"),
      JSON.stringify(workerState, null, 2),
    );
  } catch {
    // worker_state is informational; don't break session creation if cwd isn't writable
  }

  return new Session(meta, [], transcript);
}

// ----------------------------------------------------------------------------
// resumeSession
// ----------------------------------------------------------------------------

export async function resumeSession(
  sessionId: string,
  options?: { home?: string },
): Promise<Session> {
  const dir = sessionDir(sessionId, options?.home);
  if (!existsSync(dir)) {
    throw new Error(`Session not found: ${sessionId}`);
  }

  const metaFile = Bun.file(join(dir, "meta.json"));
  const meta = (await metaFile.json()) as SessionMeta;

  const transcript = new Transcript(join(dir, "transcript.jsonl"));
  const messages = await transcript.messages();

  return new Session(meta, messages, transcript);
}

// ----------------------------------------------------------------------------
// listSessions
// ----------------------------------------------------------------------------

async function readSessionsFromRoot(root: string): Promise<SessionMeta[]> {
  if (!existsSync(root)) return [];

  const entries = readdirSync(root, { withFileTypes: true });
  const metas: SessionMeta[] = [];

  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const metaPath = join(root, entry.name, "meta.json");
    try {
      const metaFile = Bun.file(metaPath);
      const exists = await metaFile.exists();
      if (!exists) continue;
      const meta = (await metaFile.json()) as SessionMeta;
      metas.push(meta);
    } catch {
      // skip corrupt session dirs
    }
  }
  return metas;
}

export async function listSessions(options?: {
  home?: string;
  /**
   * Which scope(s) to search.
   * - "user"    : only ~/.cmux101/sessions/
   * - "project" : only <cwd>/.cmux101/sessions/  (requires cwd)
   * - "all"     : both (default)
   */
  scope?: "user" | "project" | "all";
  /** Project directory; required when scope is "project" or "all". */
  cwd?: string;
}): Promise<SessionMeta[]> {
  const scope = options?.scope ?? "all";
  const metas: SessionMeta[] = [];

  if (scope === "user" || scope === "all") {
    const root = userSessionsRoot(options?.home);
    metas.push(...(await readSessionsFromRoot(root)));
  }

  if ((scope === "project" || scope === "all") && options?.cwd) {
    const root = projectSessionsRoot(options.cwd);
    metas.push(...(await readSessionsFromRoot(root)));
  }

  // Deduplicate by id (same session can't appear in both, but be safe).
  const seen = new Set<string>();
  const deduped = metas.filter((m) => {
    if (seen.has(m.id)) return false;
    seen.add(m.id);
    return true;
  });

  // Sort by startedAt descending (newest first)
  deduped.sort((a, b) => b.startedAt.localeCompare(a.startedAt));
  return deduped;
}
