import { describe, expect, test } from "bun:test";
import { normalizeCatalog } from "./direct";

// acpmux `_acpmux/harnesses` may report a harness kind this page does not know yet
// ("terminal" for a profile-file harness without ACP, or a later one). The catalog must keep
// working: every harness keeps its id, name and refusal, and no kind breaks the parse.
describe("harness kinds from acpmux", () => {
  test("an unknown or new kind never breaks the catalog", () => {
    const catalog = normalizeCatalog({
      harnesses: {
        codex: { kind: "acp", argv: ["codex-acp"], family: "codex" },
        aider: { kind: "terminal", argv: ["aider"], family: "aider", displayName: "Aider" },
        future: { kind: "some-later-kind", argv: ["x"], family: "future", unavailable: "not yet" },
      },
    });
    expect(catalog.map((h) => h.id)).toEqual(["codex", "aider", "future"]);
    expect(catalog.find((h) => h.id === "future")?.unavailable).toBe("not yet");
    expect(catalog.every((h) => Array.isArray(h.models))).toBe(true);
  });
});
