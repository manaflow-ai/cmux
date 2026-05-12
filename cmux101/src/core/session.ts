/**
 * Session: manages a cmux101 agent session on disk.
 * Sessions live under ~/.cmux101/sessions/<id>/
 */

import { existsSync, mkdirSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import type { Message, SessionHandle, SessionMeta } from "./types.js";
import { Transcript } from "./transcript.js";

// ----------------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------------

function sessionsRoot(home?: string): string {
  return join(home ?? homedir(), ".cmux101", "sessions");
}

function sessionDir(sessionId: string, home?: string): string {
  return join(sessionsRoot(home), sessionId);
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
}): Promise<Session> {
  const id = crypto.randomUUID();
  const dir = sessionDir(id, options.home);
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

export async function listSessions(options?: { home?: string }): Promise<SessionMeta[]> {
  const root = sessionsRoot(options?.home);
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

  // Sort by startedAt descending (newest first)
  metas.sort((a, b) => b.startedAt.localeCompare(a.startedAt));
  return metas;
}
