import { describe, expect, test } from "bun:test";
import type { AcpmuxSnapshot } from "./model";
import { remoteEditingNote } from "./remoteEditing";

/// A snapshot over a connection acpmux calls remote (or local), showing a session of `harness`.
const at = (remote: boolean, harness?: string, family?: string): Pick<AcpmuxSnapshot, "remote" | "summary"> => ({
  remote,
  summary: harness ? { sessionId: "s", harness, ...(family ? { family } : {}) } : undefined,
});

// acpmux lets a remote (Web) connection drive Codex only in `read-only` and opencode only in
// `plan`: neither harness has a mode that asks before every edit and every command
// (plans/cmux-next/acp-remote-guard.md, D10). The composer says why editing is not offered.
describe("remote editing note", () => {
  test("a remote connection showing a Codex or opencode chat gets the note", () => {
    expect(remoteEditingNote(at(true, "codex"))).toBe("composer.remoteEditing");
    expect(remoteEditingNote(at(true, "opencode"))).toBe("composer.remoteEditing");
  });

  test("the session's family decides, as acpmux's table does, before the profile name", () => {
    expect(remoteEditingNote(at(true, "opencode-v2", "opencode"))).toBe("composer.remoteEditing");
    expect(remoteEditingNote(at(true, "work-codex", "codex"))).toBe("composer.remoteEditing");
    expect(remoteEditingNote(at(true, "codex", "claude"))).toBeUndefined();
  });

  test("a local connection, a Claude chat, or no chat gets none", () => {
    expect(remoteEditingNote(at(false, "codex"))).toBeUndefined();
    expect(remoteEditingNote({ summary: { sessionId: "s", harness: "codex" } })).toBeUndefined();
    expect(remoteEditingNote(at(true, "claude"))).toBeUndefined();
    expect(remoteEditingNote(at(true))).toBeUndefined();
  });
});
