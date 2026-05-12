/**
 * Unit tests for Session, createSession, resumeSession, listSessions.
 * Uses a temporary directory so tests don't pollute ~/.cmux101.
 */

import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { existsSync, mkdirSync, rmSync } from "node:fs";
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

  it("replaceMessages replaces in-memory messages", async () => {
    const session = await createSession({
      cwd: "/proj",
      providerId: "anthropic",
      model: "claude-3-5-haiku",
      home: tmpHome,
    });

    const msg1: Message = { role: "user", content: [{ type: "text", text: "Hello" }] };
    const msg2: Message = { role: "assistant", content: [{ type: "text", text: "Hi" }] };
    await session.append(msg1);
    await session.append(msg2);
    expect(session.messages).toHaveLength(2);

    const compacted: Message = {
      role: "user",
      content: [{ type: "text", text: "[compacted conversation summary]\nHello / Hi" }],
    };
    await session.replaceMessages([compacted]);

    // In-memory messages replaced
    expect(session.messages).toHaveLength(1);
    expect(session.messages[0]).toEqual(compacted);
  });

  it("replaceMessages with empty array clears messages", async () => {
    const session = await createSession({
      cwd: "/proj",
      providerId: "openai",
      model: "gpt-4o",
      home: tmpHome,
    });
    const msg: Message = { role: "user", content: [{ type: "text", text: "test" }] };
    await session.append(msg);
    expect(session.messages).toHaveLength(1);

    await session.replaceMessages([]);
    expect(session.messages).toHaveLength(0);
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

// ---------------------------------------------------------------------------
// Project-scope sessions
// ---------------------------------------------------------------------------

describe("createSession with scope=project", () => {
  it("writes session files to <cwd>/.cmux101/sessions/<id>/", async () => {
    const projectCwd = join(tmpHome, "my-project");
    mkdirSync(projectCwd, { recursive: true });

    const session = await createSession({
      cwd: projectCwd,
      providerId: "anthropic",
      model: "claude-sonnet-4-5",
      home: tmpHome,
      scope: "project",
    });

    const expectedDir = join(projectCwd, ".cmux101", "sessions", session.meta.id);
    expect(existsSync(expectedDir)).toBe(true);
    expect(existsSync(join(expectedDir, "meta.json"))).toBe(true);
    expect(existsSync(join(expectedDir, "transcript.jsonl"))).toBe(true);
  });

  it("does NOT write to the user sessions dir when scope=project", async () => {
    const projectCwd = join(tmpHome, "proj-scope-test");
    mkdirSync(projectCwd, { recursive: true });

    const session = await createSession({
      cwd: projectCwd,
      providerId: "anthropic",
      model: "claude-sonnet-4-5",
      home: tmpHome,
      scope: "project",
    });

    const userDir = join(tmpHome, ".cmux101", "sessions", session.meta.id);
    expect(existsSync(userDir)).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// worker_state.json
// ---------------------------------------------------------------------------

describe("worker_state.json", () => {
  it("is written to <cwd>/.cmux101/worker_state.json on session creation", async () => {
    const projectCwd = join(tmpHome, "worker-state-test");
    mkdirSync(projectCwd, { recursive: true });

    await createSession({
      cwd: projectCwd,
      providerId: "openai",
      model: "gpt-4o",
      home: tmpHome,
    });

    const wsPath = join(projectCwd, ".cmux101", "worker_state.json");
    expect(existsSync(wsPath)).toBe(true);
  });

  it("contains expected fields", async () => {
    const projectCwd = join(tmpHome, "worker-state-fields");
    mkdirSync(projectCwd, { recursive: true });

    const workerId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
    const session = await createSession({
      cwd: projectCwd,
      providerId: "gemini",
      model: "gemini-2.5-pro",
      home: tmpHome,
      workerId,
      permissionMode: "read-only",
    });

    const wsPath = join(projectCwd, ".cmux101", "worker_state.json");
    const ws = await Bun.file(wsPath).json();

    expect(ws.workerId).toBe(workerId);
    expect(ws.sessionId).toBe(session.meta.id);
    expect(ws.providerId).toBe("gemini");
    expect(ws.model).toBe("gemini-2.5-pro");
    expect(ws.permissionMode).toBe("read-only");
    expect(typeof ws.startedAt).toBe("string");
    expect(ws.cwd).toBe(projectCwd);
  });

  it("defaults permissionMode to 'default' when not provided", async () => {
    const projectCwd = join(tmpHome, "worker-state-defaults");
    mkdirSync(projectCwd, { recursive: true });

    await createSession({
      cwd: projectCwd,
      providerId: "anthropic",
      model: "claude-haiku-4-5",
      home: tmpHome,
    });

    const ws = await Bun.file(join(projectCwd, ".cmux101", "worker_state.json")).json();
    expect(ws.permissionMode).toBe("default");
  });

  it("is overwritten on subsequent session creation in same cwd", async () => {
    const projectCwd = join(tmpHome, "worker-state-overwrite");
    mkdirSync(projectCwd, { recursive: true });

    await createSession({
      cwd: projectCwd,
      providerId: "anthropic",
      model: "claude-haiku-4-5",
      home: tmpHome,
    });

    const session2 = await createSession({
      cwd: projectCwd,
      providerId: "openai",
      model: "gpt-4o-mini",
      home: tmpHome,
    });

    const ws = await Bun.file(join(projectCwd, ".cmux101", "worker_state.json")).json();
    // Should reflect the latest session
    expect(ws.sessionId).toBe(session2.meta.id);
    expect(ws.model).toBe("gpt-4o-mini");
  });
});

// ---------------------------------------------------------------------------
// listSessions with scope options
// ---------------------------------------------------------------------------

describe("listSessions scope", () => {
  it("scope=user returns only user sessions", async () => {
    const projectCwd = join(tmpHome, "scope-user-test");
    mkdirSync(projectCwd, { recursive: true });

    // Create one user-scope and one project-scope session
    await createSession({
      cwd: projectCwd,
      providerId: "anthropic",
      model: "claude-sonnet-4-5",
      home: tmpHome,
      scope: "user",
    });
    await createSession({
      cwd: projectCwd,
      providerId: "anthropic",
      model: "claude-haiku-4-5",
      home: tmpHome,
      scope: "project",
    });

    const list = await listSessions({ home: tmpHome, scope: "user" });
    expect(list).toHaveLength(1);
    expect(list[0].model).toBe("claude-sonnet-4-5");
  });

  it("scope=project returns only project sessions", async () => {
    const projectCwd = join(tmpHome, "scope-project-test");
    mkdirSync(projectCwd, { recursive: true });

    await createSession({
      cwd: projectCwd,
      providerId: "anthropic",
      model: "claude-sonnet-4-5",
      home: tmpHome,
      scope: "user",
    });
    await createSession({
      cwd: projectCwd,
      providerId: "anthropic",
      model: "claude-haiku-4-5",
      home: tmpHome,
      scope: "project",
    });

    const list = await listSessions({ home: tmpHome, scope: "project", cwd: projectCwd });
    expect(list).toHaveLength(1);
    expect(list[0].model).toBe("claude-haiku-4-5");
  });

  it("scope=all returns both user and project sessions", async () => {
    const projectCwd = join(tmpHome, "scope-all-test");
    mkdirSync(projectCwd, { recursive: true });

    await createSession({
      cwd: projectCwd,
      providerId: "anthropic",
      model: "claude-sonnet-4-5",
      home: tmpHome,
      scope: "user",
    });
    await createSession({
      cwd: projectCwd,
      providerId: "anthropic",
      model: "claude-haiku-4-5",
      home: tmpHome,
      scope: "project",
    });

    const list = await listSessions({ home: tmpHome, scope: "all", cwd: projectCwd });
    expect(list).toHaveLength(2);
    const models = list.map((s) => s.model).sort();
    expect(models).toContain("claude-sonnet-4-5");
    expect(models).toContain("claude-haiku-4-5");
  });

  it("default scope (all) with cwd returns both scopes", async () => {
    const projectCwd = join(tmpHome, "scope-default-test");
    mkdirSync(projectCwd, { recursive: true });

    await createSession({
      cwd: projectCwd,
      providerId: "openai",
      model: "gpt-4o",
      home: tmpHome,
      scope: "user",
    });
    await createSession({
      cwd: projectCwd,
      providerId: "openai",
      model: "gpt-4o-mini",
      home: tmpHome,
      scope: "project",
    });

    const list = await listSessions({ home: tmpHome, cwd: projectCwd });
    expect(list).toHaveLength(2);
  });
});
