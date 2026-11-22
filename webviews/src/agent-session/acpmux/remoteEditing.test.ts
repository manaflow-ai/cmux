import { describe, expect, test } from "bun:test";
import type { AcpmuxSnapshot } from "./model";
import { remoteComposer } from "./remoteEditing";

type Origin = AcpmuxSnapshot["origin"];
/// A snapshot over a connection of `origin`, showing a session of `harness`.
const at = (origin: Origin, harness?: string, family?: string): Pick<AcpmuxSnapshot, "origin" | "summary"> => ({
  origin,
  summary: harness ? { sessionId: "s", harness, ...(family ? { family } : {}) } : undefined,
});

// D10: acpmux never lets a remote (Web) connection drive Codex or opencode: neither harness has
// a mode that asks before every edit and every command (plans/cmux-next/acp-remote-guard.md).
describe("remote composer state", () => {
  test("a remote connection showing a Codex or opencode chat cannot send and says why", () => {
    for (const harness of ["codex", "opencode"])
      expect(remoteComposer(at("remote", harness))).toEqual({ note: "composer.remoteUnavailable", canSend: false });
  });

  test("an older acpmux that names no origin cannot send to Codex or opencode", () => {
    for (const harness of ["codex", "opencode"])
      expect(remoteComposer(at("unknown", harness))).toEqual({ note: "composer.originUnknown", canSend: false });
  });

  test("the session's family decides, as acpmux's table does, before the profile name", () => {
    expect(remoteComposer(at("remote", "opencode-v2", "opencode")).canSend).toBe(false);
    expect(remoteComposer(at("remote", "work", "codex")).canSend).toBe(false);
    expect(remoteComposer(at("remote", "codex", "claude"))).toEqual({ canSend: true });
  });

  test("a local or peer connection, a Claude chat, no chat, or a snapshot without an origin is unchanged", () => {
    expect(remoteComposer(at("local", "codex"))).toEqual({ canSend: true });
    expect(remoteComposer(at("peer", "opencode"))).toEqual({ canSend: true });
    expect(remoteComposer(at("remote", "claude"))).toEqual({ canSend: true });
    expect(remoteComposer(at("unknown", "claude"))).toEqual({ canSend: true });
    expect(remoteComposer(at("remote"))).toEqual({ canSend: true });
    expect(remoteComposer({ summary: { sessionId: "s", harness: "codex" } })).toEqual({ canSend: true });
  });
});
