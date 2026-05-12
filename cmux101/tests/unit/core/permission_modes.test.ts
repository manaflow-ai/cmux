/**
 * Unit tests for applyPermissionMode.
 */

import { describe, it, expect } from "bun:test";
import {
  createPermissionResolver,
  applyPermissionMode,
} from "../../../src/core/permissions.js";
import type { PermissionLevel } from "../../../src/core/types.js";

function neverAskUser(_toolName: string, _input: unknown): Promise<PermissionLevel> {
  return Promise.resolve("deny");
}

function makeBase() {
  return createPermissionResolver({
    allow: ["file_read"],
    ask: ["shell"],
    deny: [],
    askUser: neverAskUser,
  });
}

// ---------------------------------------------------------------------------
// read-only
// ---------------------------------------------------------------------------

describe("applyPermissionMode('read-only')", () => {
  it("allows read-only tools", () => {
    const r = applyPermissionMode(makeBase(), "read-only");
    expect(r.resolve("file_read", {})).toBe("allow");
    expect(r.resolve("grep", {})).toBe("allow");
    expect(r.resolve("web_fetch", {})).toBe("allow");
    expect(r.resolve("glob", {})).toBe("allow");
  });

  it("denies file_write", () => {
    const r = applyPermissionMode(makeBase(), "read-only");
    expect(r.resolve("file_write", {})).toBe("deny");
  });

  it("denies shell", () => {
    const r = applyPermissionMode(makeBase(), "read-only");
    expect(r.resolve("shell", {})).toBe("deny");
  });

  it("denies unknown tools", () => {
    const r = applyPermissionMode(makeBase(), "read-only");
    expect(r.resolve("some_random_tool", {})).toBe("deny");
  });
});

// ---------------------------------------------------------------------------
// plan (same as read-only)
// ---------------------------------------------------------------------------

describe("applyPermissionMode('plan')", () => {
  it("allows read-only tools", () => {
    const r = applyPermissionMode(makeBase(), "plan");
    expect(r.resolve("file_read", {})).toBe("allow");
  });

  it("denies file_write", () => {
    const r = applyPermissionMode(makeBase(), "plan");
    expect(r.resolve("file_write", {})).toBe("deny");
  });
});

// ---------------------------------------------------------------------------
// danger-full-access
// ---------------------------------------------------------------------------

describe("applyPermissionMode('danger-full-access')", () => {
  it("allows everything", () => {
    const r = applyPermissionMode(makeBase(), "danger-full-access");
    expect(r.resolve("file_write", {})).toBe("allow");
    expect(r.resolve("shell", {})).toBe("allow");
    expect(r.resolve("some_dangerous_tool", {})).toBe("allow");
    expect(r.resolve("file_read", {})).toBe("allow");
  });
});

// ---------------------------------------------------------------------------
// auto (alias for danger-full-access)
// ---------------------------------------------------------------------------

describe("applyPermissionMode('auto')", () => {
  it("allows everything", () => {
    const r = applyPermissionMode(makeBase(), "auto");
    expect(r.resolve("file_write", {})).toBe("allow");
    expect(r.resolve("shell", {})).toBe("allow");
    expect(r.resolve("arbitrary_tool", {})).toBe("allow");
  });
});

// ---------------------------------------------------------------------------
// workspace-write
// ---------------------------------------------------------------------------

describe("applyPermissionMode('workspace-write')", () => {
  it("allows read-only tools", () => {
    const r = applyPermissionMode(makeBase(), "workspace-write");
    expect(r.resolve("file_read", {})).toBe("allow");
    expect(r.resolve("grep", {})).toBe("allow");
  });

  it("allows file_write and file_edit", () => {
    const r = applyPermissionMode(makeBase(), "workspace-write");
    expect(r.resolve("file_write", {})).toBe("allow");
    expect(r.resolve("file_edit", {})).toBe("allow");
  });

  it("asks for shell", () => {
    const r = applyPermissionMode(makeBase(), "workspace-write");
    expect(r.resolve("shell", {})).toBe("ask");
  });

  it("falls back to ask for other unknown tools", () => {
    const r = applyPermissionMode(makeBase(), "workspace-write");
    // unknown tool not in any list hits fallback -> "ask"
    expect(r.resolve("unknown_tool_xyz", {})).toBe("ask");
  });
});

// ---------------------------------------------------------------------------
// default (no override)
// ---------------------------------------------------------------------------

describe("applyPermissionMode('default')", () => {
  it("leaves config rules intact — allow list preserved", () => {
    const base = createPermissionResolver({
      allow: ["file_read"],
      deny: ["shell"],
      askUser: neverAskUser,
    });
    const r = applyPermissionMode(base, "default");
    expect(r.resolve("file_read", {})).toBe("allow");
    expect(r.resolve("shell", {})).toBe("deny");
    expect(r.resolve("unknown", {})).toBe("ask");
  });

  it("returns the same resolver instance", () => {
    const base = makeBase();
    const r = applyPermissionMode(base, "default");
    expect(r).toBe(base);
  });
});
