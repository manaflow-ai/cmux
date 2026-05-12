/**
 * Unit tests for PermissionResolver.
 */

import { describe, it, expect } from "bun:test";
import {
  createPermissionResolver,
  matchGlob,
  PermissionResolver,
} from "../../../src/core/permissions.js";
import type { PermissionLevel } from "../../../src/core/types.js";

// ---------------------------------------------------------------------------
// matchGlob
// ---------------------------------------------------------------------------

describe("matchGlob", () => {
  it("exact match returns true", () => {
    expect(matchGlob("shell", "shell")).toBe(true);
  });

  it("exact match fails for different name", () => {
    expect(matchGlob("shell", "bash")).toBe(false);
  });

  it("glob * matches suffix", () => {
    expect(matchGlob("cmux_close_*", "cmux_close_tab")).toBe(true);
    expect(matchGlob("cmux_close_*", "cmux_close_window")).toBe(true);
  });

  it("glob * does not match unrelated names", () => {
    expect(matchGlob("cmux_close_*", "cmux_open_tab")).toBe(false);
  });

  it("glob * at start matches prefix patterns", () => {
    expect(matchGlob("*_read", "file_read")).toBe(true);
    expect(matchGlob("*_read", "file_write")).toBe(false);
  });

  it("glob * in middle matches", () => {
    expect(matchGlob("file_*_v2", "file_read_v2")).toBe(true);
    expect(matchGlob("file_*_v2", "file_write_v2")).toBe(true);
    expect(matchGlob("file_*_v2", "file_read_v3")).toBe(false);
  });

  it("bare * matches everything", () => {
    expect(matchGlob("*", "any_tool")).toBe(true);
    expect(matchGlob("*", "")).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function neverAskUser(_toolName: string, _input: unknown): Promise<PermissionLevel> {
  return Promise.resolve("deny");
}

// ---------------------------------------------------------------------------
// Priority ordering: deny > allow > ask > default > fallback
// ---------------------------------------------------------------------------

describe("PermissionResolver – priority ordering", () => {
  it("deny > allow: deny wins when tool is in both lists", () => {
    const r = createPermissionResolver({
      allow: ["shell"],
      deny: ["shell"],
      askUser: neverAskUser,
    });
    expect(r.resolve("shell", {})).toBe("deny");
  });

  it("allow > ask: allow wins when tool is in both lists", () => {
    const r = createPermissionResolver({
      allow: ["file_read"],
      ask: ["file_read"],
      askUser: neverAskUser,
    });
    expect(r.resolve("file_read", {})).toBe("allow");
  });

  it("ask > default: ask list wins over defaults map", () => {
    const defaults = new Map<string, PermissionLevel>([["web_fetch", "allow"]]);
    const r = createPermissionResolver({
      ask: ["web_fetch"],
      defaults,
      askUser: neverAskUser,
    });
    expect(r.resolve("web_fetch", {})).toBe("ask");
  });

  it("default > fallback: uses defaults map when not in any list", () => {
    const defaults = new Map<string, PermissionLevel>([["special_tool", "allow"]]);
    const r = createPermissionResolver({
      defaults,
      askUser: neverAskUser,
    });
    expect(r.resolve("special_tool", {})).toBe("allow");
  });

  it("fallback is ask when tool is unknown and not in any list", () => {
    const r = createPermissionResolver({ askUser: neverAskUser });
    expect(r.resolve("unknown_tool", {})).toBe("ask");
  });

  it("deny glob wins over allow exact", () => {
    const r = createPermissionResolver({
      allow: ["cmux_close_tab"],
      deny: ["cmux_close_*"],
      askUser: neverAskUser,
    });
    expect(r.resolve("cmux_close_tab", {})).toBe("deny");
  });
});

// ---------------------------------------------------------------------------
// remember
// ---------------------------------------------------------------------------

describe("PermissionResolver – remember", () => {
  it("session scope: remembered value is returned on subsequent resolve", () => {
    const r = createPermissionResolver({
      askUser: neverAskUser,
    });
    // Before: unknown -> ask
    expect(r.resolve("shell", {})).toBe("ask");

    r.remember("shell", "allow", "session");

    // After: overridden to allow
    expect(r.resolve("shell", {})).toBe("allow");
  });

  it("remembered value overrides deny list", () => {
    const r = createPermissionResolver({
      deny: ["shell"],
      askUser: neverAskUser,
    });
    expect(r.resolve("shell", {})).toBe("deny");

    r.remember("shell", "allow", "session");
    expect(r.resolve("shell", {})).toBe("allow");
  });

  it("remember deny overrides allow list", () => {
    const r = createPermissionResolver({
      allow: ["file_read"],
      askUser: neverAskUser,
    });
    expect(r.resolve("file_read", {})).toBe("allow");

    r.remember("file_read", "deny", "session");
    expect(r.resolve("file_read", {})).toBe("deny");
  });

  it("multiple tools can be remembered independently", () => {
    const r = createPermissionResolver({ askUser: neverAskUser });
    r.remember("tool_a", "allow", "session");
    r.remember("tool_b", "deny", "session");

    expect(r.resolve("tool_a", {})).toBe("allow");
    expect(r.resolve("tool_b", {})).toBe("deny");
  });
});

// ---------------------------------------------------------------------------
// narrow
// ---------------------------------------------------------------------------

describe("PermissionResolver – narrow", () => {
  it("only allows listed tools; everything else is deny", () => {
    const r = createPermissionResolver({
      allow: ["shell", "file_read", "web_fetch"],
      askUser: neverAskUser,
    });
    const narrow = r.narrow(["file_read"]);

    expect(narrow.resolve("file_read", {})).toBe("allow");
    expect(narrow.resolve("shell", {})).toBe("deny");
    expect(narrow.resolve("web_fetch", {})).toBe("deny");
    expect(narrow.resolve("unknown", {})).toBe("deny");
  });

  it("narrow with empty list denies everything", () => {
    const r = createPermissionResolver({
      allow: ["shell"],
      askUser: neverAskUser,
    });
    const narrow = r.narrow([]);

    expect(narrow.resolve("shell", {})).toBe("deny");
    expect(narrow.resolve("anything", {})).toBe("deny");
  });

  it("narrow returns a Permissions-compatible object", () => {
    const r = createPermissionResolver({ askUser: neverAskUser });
    const narrow = r.narrow(["tool_x"]);
    expect(typeof narrow.resolve).toBe("function");
    expect(typeof narrow.remember).toBe("function");
    expect(typeof narrow.narrow).toBe("function");
  });

  it("double narrow further restricts tools", () => {
    const r = createPermissionResolver({ askUser: neverAskUser });
    const narrow1 = r.narrow(["file_read", "file_write"]);
    const narrow2 = narrow1.narrow(["file_read"]);

    expect(narrow2.resolve("file_read", {})).toBe("allow");
    expect(narrow2.resolve("file_write", {})).toBe("deny");
  });

  it("remembered session value overrides narrow deny", () => {
    const r = createPermissionResolver({ askUser: neverAskUser });
    const narrow = r.narrow(["file_read"]) as PermissionResolver;

    expect(narrow.resolve("shell", {})).toBe("deny");
    narrow.remember("shell", "allow", "session");
    expect(narrow.resolve("shell", {})).toBe("allow");
  });

  it("narrow supports glob patterns in allowed list", () => {
    const r = createPermissionResolver({ askUser: neverAskUser });
    const narrow = r.narrow(["cmux_close_*"]);

    expect(narrow.resolve("cmux_close_tab", {})).toBe("allow");
    expect(narrow.resolve("cmux_close_window", {})).toBe("allow");
    expect(narrow.resolve("cmux_open_tab", {})).toBe("deny");
  });
});

// ---------------------------------------------------------------------------
// askUser callback
// ---------------------------------------------------------------------------

describe("PermissionResolver – askUser integration", () => {
  it("askUserFor delegates to the provided callback", async () => {
    const calls: [string, unknown][] = [];
    const r = createPermissionResolver({
      askUser: async (toolName, input) => {
        calls.push([toolName, input]);
        return "allow";
      },
    });

    const result = await r.askUserFor("shell", { cmd: "ls" });
    expect(result).toBe("allow");
    expect(calls).toHaveLength(1);
    expect(calls[0]).toEqual(["shell", { cmd: "ls" }]);
  });
});
