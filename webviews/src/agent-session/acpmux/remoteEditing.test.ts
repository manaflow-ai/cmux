import { expect, test } from "bun:test";
import { remoteComposer } from "./remoteEditing";

const chat = (family: string) => ({ summary: { family } }) as Parameters<typeof remoteComposer>[0];

test("a remote Codex or opencode chat cannot send, except on the person's own Cloud machine", () => {
  for (const family of ["codex", "opencode"]) {
    expect(remoteComposer({ ...chat(family), origin: "remote" })).toEqual({
      note: "composer.remoteUnavailable",
      canSend: false,
    });
    expect(remoteComposer({ ...chat(family), origin: "remote", ownerCloud: true })).toEqual({ canSend: true });
    // An origin acpmux has not named yet sends; acpmux itself refuses a remote one.
    expect(remoteComposer({ ...chat(family), origin: "unknown" })).toEqual({ canSend: true });
    expect(remoteComposer({ ...chat(family), origin: "local" })).toEqual({ canSend: true });
  }
  expect(remoteComposer({ ...chat("claude"), origin: "remote" })).toEqual({ canSend: true });
});
