import { describe, expect, it } from "vitest";
import {
  legacyContentToNestedEnvVars,
  nestedEnvVarsToLegacyContent,
  removePathEnvVars,
  resolveNestedEnvVars,
  setPathEnvVars,
  type NestedEnvVars,
} from "./environment-vars";

describe("environment-vars", () => {
  describe("resolveNestedEnvVars", () => {
    it("should resolve global variables for any path", () => {
      const nested: NestedEnvVars = {
        global: [
          { name: "GLOBAL_VAR", value: "global", isSecret: false },
          { name: "API_KEY", value: "global-key", isSecret: true },
        ],
        paths: [],
      };

      const resolved = resolveNestedEnvVars(nested, "apps/frontend");

      expect(resolved).toEqual({
        GLOBAL_VAR: "global",
        API_KEY: "global-key",
      });
    });

    it("should override global variables with path-specific ones", () => {
      const nested: NestedEnvVars = {
        global: [
          { name: "API_KEY", value: "global-key", isSecret: true },
          { name: "GLOBAL_VAR", value: "global", isSecret: false },
        ],
        paths: [
          {
            path: "apps/frontend",
            variables: [
              { name: "API_KEY", value: "frontend-key", isSecret: true },
            ],
          },
        ],
      };

      const resolved = resolveNestedEnvVars(nested, "apps/frontend");

      expect(resolved).toEqual({
        API_KEY: "frontend-key", // Overridden
        GLOBAL_VAR: "global", // Inherited
      });
    });

    it("should apply parent path variables to child paths", () => {
      const nested: NestedEnvVars = {
        global: [
          { name: "GLOBAL_VAR", value: "global", isSecret: false },
        ],
        paths: [ 
          {
            path: "apps",
            variables: [
              { name: "APPS_VAR", value: "apps", isSecret: false },
            ],
          },
          {
            path: "apps/frontend",
            variables: [
              { name: "FRONTEND_VAR", value: "frontend", isSecret: false },
            ],
          },
        ],
      };

      const resolved = resolveNestedEnvVars(nested, "apps/frontend");

      expect(resolved).toEqual({
        GLOBAL_VAR: "global",
        APPS_VAR: "apps",
        FRONTEND_VAR: "frontend",
      });
    });

    it("should respect hierarchy when overriding", () => {
      const nested: NestedEnvVars = {
        global: [
          { name: "VAR", value: "global", isSecret: false },
        ],
        paths: [
          {
            path: "apps",
            variables: [
              { name: "VAR", value: "apps", isSecret: false },
            ],
          },
          {
            path: "apps/frontend",
            variables: [
              { name: "VAR", value: "frontend", isSecret: false },
            ],
          },
        ],
      };

      const resolved = resolveNestedEnvVars(nested, "apps/frontend");
      expect(resolved.VAR).toBe("frontend");

      const resolvedApps = resolveNestedEnvVars(nested, "apps");
      expect(resolvedApps.VAR).toBe("apps");

      const resolvedRoot = resolveNestedEnvVars(nested, ".");
      expect(resolvedRoot.VAR).toBe("global");
    });

    it("should handle root path (.)", () => {
      const nested: NestedEnvVars = {
        global: [],
        paths: [
          {
            path: ".",
            variables: [
              { name: "ROOT_VAR", value: "root", isSecret: false },
            ],
          },
        ],
      };

      const resolved = resolveNestedEnvVars(nested, ".");
      expect(resolved.ROOT_VAR).toBe("root");

      const resolvedChild = resolveNestedEnvVars(nested, "apps/frontend");
      expect(resolvedChild.ROOT_VAR).toBe("root");
    });

    it("should not apply sibling path variables", () => {
      const nested: NestedEnvVars = {
        global: [],
        paths: [
          {
            path: "apps/frontend",
            variables: [
              { name: "FRONTEND_VAR", value: "frontend", isSecret: false },
            ],
          },
          {
            path: "apps/backend",
            variables: [
              { name: "BACKEND_VAR", value: "backend", isSecret: false },
            ],
          },
        ],
      };

      const resolvedFrontend = resolveNestedEnvVars(nested, "apps/frontend");
      expect(resolvedFrontend.FRONTEND_VAR).toBe("frontend");
      expect(resolvedFrontend.BACKEND_VAR).toBeUndefined();

      const resolvedBackend = resolveNestedEnvVars(nested, "apps/backend");
      expect(resolvedBackend.BACKEND_VAR).toBe("backend");
      expect(resolvedBackend.FRONTEND_VAR).toBeUndefined();
    });
  });

  describe("nestedEnvVarsToLegacyContent", () => {
    it("should convert nested to legacy format", () => {
      const nested: NestedEnvVars = {
        global: [
          { name: "GLOBAL_VAR", value: "global", isSecret: false },
        ],
        paths: [
          {
            path: "apps/frontend",
            variables: [
              { name: "FRONTEND_VAR", value: "frontend", isSecret: false },
            ],
          },
        ],
      };

      const legacy = nestedEnvVarsToLegacyContent(nested);

      expect(legacy).toContain("GLOBAL_VAR=global");
      expect(legacy).toContain("FRONTEND_VAR=frontend");
      expect(legacy).toContain("# Global variables");
      expect(legacy).toContain("# apps/frontend");
    });

    it("should handle empty nested structure", () => {
      const nested: NestedEnvVars = {
        global: [],
        paths: [],
      };

      const legacy = nestedEnvVarsToLegacyContent(nested);
      expect(legacy).toBe("");
    });

    it("should escape values with quotes", () => {
      const nested: NestedEnvVars = {
        global: [
          { name: "JSON_CONFIG", value: '{"key": "value"}', isSecret: false },
        ],
        paths: [],
      };

      const legacy = nestedEnvVarsToLegacyContent(nested);
      expect(legacy).toContain('JSON_CONFIG="{\\"key\\": \\"value\\"}"');
    });
  });

  describe("legacyContentToNestedEnvVars", () => {
    it("should convert legacy to nested format", () => {
      const legacy = `
GLOBAL_VAR=global
API_KEY=secret123
      `.trim();

      const nested = legacyContentToNestedEnvVars(legacy);

      expect(nested.global).toHaveLength(2);
      expect(nested.global[0]).toEqual({
        name: "GLOBAL_VAR",
        value: "global",
        isSecret: true,
      });
      expect(nested.global[1]).toEqual({
        name: "API_KEY",
        value: "secret123",
        isSecret: true,
      });
      expect(nested.paths).toEqual([]);
    });

    it("should handle comments and empty lines", () => {
      const legacy = `
# This is a comment
VALID_VAR=value

# Another comment
ANOTHER_VAR=value2
      `.trim();

      const nested = legacyContentToNestedEnvVars(legacy);

      expect(nested.global).toHaveLength(2);
      expect(nested.global[0]?.name).toBe("VALID_VAR");
      expect(nested.global[1]?.name).toBe("ANOTHER_VAR");
    });

    it("should handle quoted values", () => {
      const legacy = `VAR1="quoted value"
VAR2='single quoted'`;

      const nested = legacyContentToNestedEnvVars(legacy);

      expect(nested.global[0]?.value).toBe("quoted value");
      expect(nested.global[1]?.value).toBe("single quoted");
    });
  });

  describe("setPathEnvVars", () => {
    it("should add new path configuration", () => {
      const nested: NestedEnvVars = {
        global: [],
        paths: [],
      };

      const updated = setPathEnvVars(
        nested,
        "apps/frontend",
        [{ name: "VAR", value: "value", isSecret: false }],
        "Frontend config"
      );

      expect(updated.paths).toHaveLength(1);
      expect(updated.paths[0]).toEqual({
        path: "apps/frontend",
        description: "Frontend config",
        variables: [{ name: "VAR", value: "value", isSecret: false }],
      });
    });

    it("should update existing path configuration", () => {
      const nested: NestedEnvVars = {
        global: [],
        paths: [
          {
            path: "apps/frontend",
            description: "Old description",
            variables: [{ name: "OLD_VAR", value: "old", isSecret: false }],
          },
        ],
      };

      const updated = setPathEnvVars(
        nested,
        "apps/frontend",
        [{ name: "NEW_VAR", value: "new", isSecret: false }],
        "New description"
      );

      expect(updated.paths).toHaveLength(1);
      expect(updated.paths[0]?.variables[0]?.name).toBe("NEW_VAR");
      expect(updated.paths[0]?.description).toBe("New description");
    });
  });

  describe("removePathEnvVars", () => {
    it("should remove path configuration", () => {
      const nested: NestedEnvVars = {
        global: [],
        paths: [
          {
            path: "apps/frontend",
            variables: [{ name: "VAR", value: "value", isSecret: false }],
          },
          {
            path: "apps/backend",
            variables: [{ name: "VAR2", value: "value2", isSecret: false }],
          },
        ],
      };

      const updated = removePathEnvVars(nested, "apps/frontend");

      expect(updated.paths).toHaveLength(1);
      expect(updated.paths[0]?.path).toBe("apps/backend");
    });
  });
});
