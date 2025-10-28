import { z } from "zod";

/**
 * Represents a single environment variable entry
 */
export const EnvVarEntrySchema = z.object({
  name: z.string(),
  value: z.string(),
  isSecret: z.boolean(),
});

export type EnvVarEntry = z.infer<typeof EnvVarEntrySchema>;

/**
 * Represents environment variables for a specific path in the workspace
 */
export const PathEnvVarsSchema = z.object({
  path: z.string().describe("Relative path from workspace root (e.g., 'apps/frontend', '.')"),
  description: z.string().optional().describe("Optional description for this path's configuration"),
  variables: z.array(EnvVarEntrySchema),
});

export type PathEnvVars = z.infer<typeof PathEnvVarsSchema>;

/**
 * Complete nested environment variables structure
 *
 * Structure:
 * - global: Variables applied to all paths (lowest priority)
 * - paths: Array of path-specific configurations (higher priority)
 *
 * Resolution order (lowest to highest priority):
 * 1. global variables
 * 2. parent path variables
 * 3. child path variables
 *
 * Example:
 * {
 *   global: [{ name: "API_KEY", value: "global-key", isSecret: true }],
 *   paths: [
 *     {
 *       path: "apps",
 *       variables: [{ name: "APPS_VAR", value: "apps-value", isSecret: false }]
 *     },
 *     {
 *       path: "apps/frontend",
 *       variables: [{ name: "API_KEY", value: "frontend-key", isSecret: true }]
 *     }
 *   ]
 * }
 *
 * When resolving for "apps/frontend", the result will be:
 * {
 *   "API_KEY": "frontend-key",  // Overridden by apps/frontend
 *   "APPS_VAR": "apps-value"     // Inherited from apps
 * }
 */
export const NestedEnvVarsSchema = z.object({
  global: z.array(EnvVarEntrySchema).describe("Global variables applied to all paths"),
  paths: z.array(PathEnvVarsSchema).describe("Path-specific variable configurations"),
});

export type NestedEnvVars = z.infer<typeof NestedEnvVarsSchema>;

/**
 * Legacy format for backward compatibility
 * A simple string containing .env file content
 */
export type LegacyEnvVarsContent = string;

/**
 * Converts nested env vars to the legacy flat .env content format
 * This is used for backward compatibility with existing code
 */
export function nestedEnvVarsToLegacyContent(nested: NestedEnvVars): string {
  const lines: string[] = [];

  // Add global variables
  if (nested.global.length > 0) {
    lines.push("# Global variables");
    for (const envVar of nested.global) {
      if (envVar.name.trim()) {
        const escapedValue = envVar.value.includes("\n") || envVar.value.includes('"')
          ? `"${envVar.value.replace(/"/g, '\\"')}"`
          : envVar.value;
        lines.push(`${envVar.name}=${escapedValue}`);
      }
    }
    lines.push("");
  }

  // Add path-specific variables
  for (const pathConfig of nested.paths) {
    if (pathConfig.variables.length > 0) {
      lines.push(`# ${pathConfig.path}${pathConfig.description ? ` - ${pathConfig.description}` : ""}`);
      for (const envVar of pathConfig.variables) {
        if (envVar.name.trim()) {
          const escapedValue = envVar.value.includes("\n") || envVar.value.includes('"')
            ? `"${envVar.value.replace(/"/g, '\\"')}"`
            : envVar.value;
          lines.push(`${envVar.name}=${escapedValue}`);
        }
      }
      lines.push("");
    }
  }

  return lines.join("\n").trim();
}

/**
 * Converts legacy .env content to nested env vars format
 * All variables go into the global section for backward compatibility
 */
export function legacyContentToNestedEnvVars(content: string): NestedEnvVars {
  const lines = content.split("\n");
  const global: EnvVarEntry[] = [];

  for (const line of lines) {
    const trimmed = line.trim();

    // Skip empty lines and comments
    if (!trimmed || trimmed.startsWith("#")) {
      continue;
    }

    // Parse KEY=VALUE
    const match = trimmed.match(/^([^=]+)=(.*)$/);
    if (match) {
      const [, name, value] = match;
      if (name) {
        // Remove quotes if present
        let cleanValue = value || "";
        if ((cleanValue.startsWith('"') && cleanValue.endsWith('"')) ||
            (cleanValue.startsWith("'") && cleanValue.endsWith("'"))) {
          cleanValue = cleanValue.slice(1, -1);
        }

        global.push({
          name: name.trim(),
          value: cleanValue,
          isSecret: true, // Default to secret for safety
        });
      }
    }
  }

  return {
    global,
    paths: [],
  };
}

/**
 * Resolves environment variables for a specific target path
 * using the nested configuration
 *
 * @param nested - The nested env vars configuration
 * @param targetPath - The path to resolve variables for (e.g., "apps/frontend")
 * @returns Resolved flat key-value map
 */
export function resolveNestedEnvVars(
  nested: NestedEnvVars,
  targetPath: string
): Record<string, string> {
  const resolved: Record<string, string> = {};

  // Start with global variables
  for (const envVar of nested.global) {
    if (envVar.name.trim()) {
      resolved[envVar.name] = envVar.value;
    }
  }

  // Normalize target path
  const normalizedTarget = targetPath.replace(/^\.\//, "").replace(/\/$/, "");

  // Apply path-specific variables in order of specificity
  // Sort paths by depth (shallowest first)
  const sortedPaths = [...nested.paths].sort((a, b) => {
    const depthA = a.path === "." ? 0 : a.path.split("/").length;
    const depthB = b.path === "." ? 0 : b.path.split("/").length;
    return depthA - depthB;
  });

  for (const pathConfig of sortedPaths) {
    const normalizedPath = pathConfig.path.replace(/^\.\//, "").replace(/\/$/, "");

    // Check if this path applies to the target
    // It applies if:
    // 1. It's an exact match
    // 2. The target is a child of this path
    const isExactMatch = normalizedPath === normalizedTarget;
    const isParent = normalizedPath === "." ||
                     normalizedTarget.startsWith(normalizedPath + "/");

    if (isExactMatch || isParent) {
      for (const envVar of pathConfig.variables) {
        if (envVar.name.trim()) {
          resolved[envVar.name] = envVar.value;
        }
      }
    }
  }

  return resolved;
}

/**
 * Gets all unique paths defined in the nested env vars
 */
export function getDefinedPaths(nested: NestedEnvVars): string[] {
  return nested.paths.map(p => p.path);
}

/**
 * Adds or updates environment variables for a specific path
 */
export function setPathEnvVars(
  nested: NestedEnvVars,
  path: string,
  variables: EnvVarEntry[],
  description?: string
): NestedEnvVars {
  const existingIndex = nested.paths.findIndex(p => p.path === path);

  if (existingIndex >= 0) {
    // Update existing path
    const updatedPaths = [...nested.paths];
    updatedPaths[existingIndex] = {
      ...updatedPaths[existingIndex]!,
      variables,
      ...(description !== undefined ? { description } : {}),
    };
    return {
      ...nested,
      paths: updatedPaths,
    };
  } else {
    // Add new path
    return {
      ...nested,
      paths: [
        ...nested.paths,
        {
          path,
          variables,
          ...(description ? { description } : {}),
        },
      ],
    };
  }
}

/**
 * Removes environment variables for a specific path
 */
export function removePathEnvVars(nested: NestedEnvVars, path: string): NestedEnvVars {
  return {
    ...nested,
    paths: nested.paths.filter(p => p.path !== path),
  };
}
