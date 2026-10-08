/**
 * Upstream names carry the environment, so staging resources on the shared
 * provider account are told apart from production and from other cmux
 * systems. The lifecycle and snapshot tests check the full name end to end.
 */
import { describe, expect, it } from "vitest";
import type { Environment } from "../../src/policy.ts";
import { upstreamName, upstreamNamePrefix } from "../../src/upstream/naming.ts";

describe("upstream names", () => {
  const environments: ReadonlyArray<Environment> = ["local", "preview", "staging", "production"];

  it("start with the environment prefix", () => {
    expect(upstreamName("staging", "team_a", "vm_0123456789abcdefghjkmnpqrs")).toBe("cmux-vm-staging team_a vm_0123456789abcdefghjkmnpqrs");
    for (const environment of environments) {
      expect(upstreamName(environment, "team_a", "snap_x").startsWith(upstreamNamePrefix(environment))).toBe(true);
    }
  });

  it("never match another environment's prefix or the classic cmux names", () => {
    for (const environment of environments) {
      const made = upstreamName(environment, "team_a", "vm_x");
      for (const other of environments) {
        if (other !== environment) expect(made.startsWith(upstreamNamePrefix(other))).toBe(false);
      }
      expect(made.startsWith("cmux ")).toBe(false);
    }
  });
});
