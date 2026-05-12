/**
 * Unit tests for Session, createSession, resumeSession, listSessions.
 * Uses a temporary directory so tests don't pollute ~/.cmux101.
 */

import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { createSession, resumeSession, listSessions } from "../../../src/core/session.js";
import type { Message } from "../../../src/core/types.js";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

let tmpHome: string;

function uniqueTmp(): string {
  return join(tmpdir(), `cmux101-test-${crypto.randomUUID()}`);
}

beforeEach(() => {
  tmpHome = uniqueTmp();
  mkdirSync(tmpHome, { recursive: true });
});

afterEach(() => {
  rmSync(tmpHome, { recursive: true, force: true });
});

// ---------------------------------------------------------------------------
// createSession + append + reload roundtrip
// ---------------------------------------------------------------------------

describe("createSession", () => {
  it("creates a session with correct meta", async () => {
    const session = await createSession({
      cwd: "/some/project",
      providerId: "anthropic",
      model: "claude-3-5-sonnet",
      home: tmpHome,
    });

    expect(session.meta.providerId).toBe("anthropic");
    expect(session.meta.model).toBe("claude-3-5-sonnet");
    expect(session.meta.cwd).toBe("/some/project");
    expect(session.meta.id).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
    );
    expect(session.messages).toHaveLength(0);
  });

  it("append + reload roundtrip preserves messages", async () => {
    const session = await createSession({
      cwd: "/proj",
      providerId: "openai",
      model: "gpt-4o",
      home: tmpHome,
    });

    const msg1: Message = {
      role: "user",
      content: [{ type: "text", text: "Hello!" }],
    };
    const msg2: Message = {
      role: "assistant",
      content: [{ type: "text", text: "Hi there!" }],
    };

    await session.append(msg1);
    await session.append(msg2);

    expect(session.messages).toHaveLength(2);
    expect(session.messages[0]).toEqual(msg1);
    expect(session.messages[1]).toEqual(msg2);

    // Reload from disk
    const resumed = await resumeSession(session.meta.id, { home: tmpHome });
    expect(resumed.messages).toHaveLength(2);
    expect(resumed.messages[0]).toEqual(msg1);
    expect(resumed.messages[1]).toEqual(msg2);
  });

  it("recordEvent writes a custom event to transcript", async () => {
    const session = await createSession({
      cwd: "/proj",
      providerId: "anthropic",
      model: "claude-3-5-haiku",
      home: tmpHome,
    });

    await session.recordEvent({ kind: "hook.fired", data: { name: "test" } });

    // Messages count is unaffected
    const resumed = await resumeSession(session.meta.id, { home: tmpHome });
    expect(resumed.messages).toHaveLength(0);
  });
});

// ---------------------------------------------------------------------------
// resumeSession
// ---------------------------------------------------------------------------

describe("resumeSession", () => {
  it("loads messages correctly", async () => {
    const session = await createSession({
      cwd: "/my-project",
      providerId: "gemini",
      model: "gemini-2.0-flash",
      home: tmpHome,
    });

    const msgs: Message[] = [
      { role: "user", content: [{ type: "text", text: "What is 2+2?" }] },
      { role: "assistant", content: [{ type: "text", text: "4" }] },
      { role: "user", content: [{ type: "text", text: "And 3+3?" }] },
      { role: "assistant", content: [{ type: "text", text: "6" }] },
    ];
    for (const m of msgs) await session.append(m);

    const resumed = await resumeSession(session.meta.id, { home: tmpHome });
    expect(resumed.meta.id).toBe(session.meta.id);
    expect(resumed.meta.cwd).toBe("/my-project");
    expect(resumed.messages).toHaveLength(4);
    for (let i = 0; i < msgs.length; i++) {
      expect(resumed.messages[i]).toEqual(msgs[i]);
    }
  });

  it("throws when session id does not exist", async () => {
    await expect(
      resumeSession("00000000-0000-0000-0000-000000000000", { home: tmpHome }),
    ).rejects.toThrow();
  });
});

// ---------------------------------------------------------------------------
// listSessions
// ---------------------------------------------------------------------------

describe("listSessions", () => {
  it("returns empty array when no sessions exist", async () => {
    const list = await listSessions({ home: tmpHome });
    expect(list).toEqual([]);
  });

  it("returns all sessions sorted by startedAt descending", async () => {
    // Create sessions with small delays to ensure distinct timestamps
    const s1 = await createSession({
      cwd: "/p1",
      providerId: "anthropic",
      model: "claude-opus-4",
      home: tmpHome,
    });

    // Force a different startedAt for s2 by patching meta
    await Bun.write(
      join(tmpHome, ".cmux101", "sessions", s1.meta.id, "meta.json"),
      JSON.stringify({ ...s1.meta, startedAt: "2024-01-01T00:00:00.000Z" }, null, 2),
    );

    const s2 = await createSession({
      cwd: "/p2",
      providerId: "openai",
      model: "gpt-4o",
      home: tmpHome,
    });

    await Bun.write(
      join(tmpHome, ".cmux101", "sessions", s2.meta.id, "meta.json"),
      JSON.stringify({ ...s2.meta, startedAt: "2025-06-01T00:00:00.000Z" }, null, 2),
    );

    const list = await listSessions({ home: tmpHome });
    expect(list).toHaveLength(2);
    // Newest first
    expect(list[0].startedAt).toBe("2025-06-01T00:00:00.000Z");
    expect(list[1].startedAt).toBe("2024-01-01T00:00:00.000Z");
  });

  it("includes correct meta fields", async () => {
    await createSession({
      cwd: "/check-meta",
      providerId: "bedrock",
      model: "claude-3-haiku",
      system: "You are a helpful assistant.",
      home: tmpHome,
    });

    const list = await listSessions({ home: tmpHome });
    expect(list).toHaveLength(1);
    const meta = list[0];
    expect(meta.cwd).toBe("/check-meta");
    expect(meta.providerId).toBe("bedrock");
    expect(meta.model).toBe("claude-3-haiku");
    expect(meta.system).toBe("You are a helpful assistant.");
  });
});
