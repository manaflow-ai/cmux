/**
 * Decision CMUX-VM-API V2: every operation of the pinned upstream surface is
 * either wrapped by a cmux VM endpoint, planned under a named task, or denied
 * with a reason (upstream/coverage.json). A refresh of the pinned surface that
 * adds an operation, an SDK method or a CLI command fails here until someone
 * classifies it.
 */
import { describe, expect, it } from "vitest";
import cmuxOpenApi from "../../openapi.json?raw";
import coverageJson from "../../upstream/coverage.json?raw";
import upstreamOpenApi from "../../upstream/openapi.json?raw";

/** Every .d.ts file of the pinned SDK, keyed by its path below upstream/sdk/. */
const declarations: ReadonlyArray<readonly [string, string]> = Object.entries(
  import.meta.glob("../../upstream/sdk/**/*.d.ts", { query: "?raw", import: "default", eager: true }),
)
  .map(([path, text]) => [path.replace(/^.*\/upstream\/sdk\//, ""), text] as const)
  .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));

interface OpenApiDocument {
  readonly paths: Record<string, Record<string, { readonly operationId?: string }>>;
}

const METHODS = new Set(["get", "put", "post", "delete", "patch", "head", "options", "trace"]);

const operationIds = (document: OpenApiDocument): string[] =>
  Object.entries(document.paths).flatMap(([path, item]) =>
    Object.entries(item)
      .filter(([method]) => METHODS.has(method))
      .map(([method, operation]) => operation.operationId ?? `${method.toUpperCase()} ${path}`),
  );

type OperationEntry =
  | { readonly status: "wrapped"; readonly by: ReadonlyArray<string> }
  | { readonly status: "planned"; readonly bead: string; readonly reason: string }
  | { readonly status: "denied"; readonly reason: string };

type SurfaceEntry =
  | { readonly operations: ReadonlyArray<string> }
  | { readonly status: "denied" | "local"; readonly reason: string };

interface Coverage {
  readonly operations: Record<string, OperationEntry>;
  readonly sdk: Record<string, SurfaceEntry>;
  readonly cli: Record<string, SurfaceEntry>;
}

const upstreamOps = operationIds(JSON.parse(upstreamOpenApi));
const cmuxOps = new Set(operationIds(JSON.parse(cmuxOpenApi)));
const coverage: Coverage = JSON.parse(coverageJson);

/** `Class.method` for every public method of every class the SDK declares (the CLI is listed separately). */
const sdkMethods = (): string[] => {
  const found: string[] = [];
  for (const [file, text] of declarations) {
    if (file.startsWith("cli/")) continue;
    for (const match of text.matchAll(/^export declare class (\w+)[^{]*\{\n([\s\S]*?)^\}/gm)) {
      const [, className, body] = match;
      for (const method of (body ?? "").matchAll(/^ {4}(?!private |protected |readonly |static |constructor|get |set )(\w+)\s*(?:<[^(]*>)?\(/gm)) {
        found.push(`${className}.${method[1]}`);
      }
    }
  }
  return found;
};

/** Every command module the CLI exports from cli/commands/. */
const cliCommands = (): string[] =>
  declarations
    .filter(([file]) => file.startsWith("cli/commands/"))
    .flatMap(([, text]) =>
    Array.from(text.matchAll(/^export declare const (\w+Commands?)\b/gm), (match) => String(match[1])),
  );

const BEAD = /^cx-[a-z0-9]+(\.[0-9]+)*$/;

describe("upstream operation coverage", () => {
  it("reads a non-trivial pinned surface", () => {
    expect(upstreamOps.length).toBeGreaterThan(50);
    expect(new Set(upstreamOps).size).toBe(upstreamOps.length);
  });

  it("classifies every upstream operation", () => {
    const missing = upstreamOps.filter((operation) => !(operation in coverage.operations));
    expect(missing, "upstream operations with no entry in upstream/coverage.json").toEqual([]);
  });

  it("has no entries for operations the upstream no longer has", () => {
    const known = new Set(upstreamOps);
    expect(Object.keys(coverage.operations).filter((operation) => !known.has(operation))).toEqual([]);
  });

  it("names a published cmux endpoint for every wrapped operation", () => {
    const broken = Object.entries(coverage.operations).flatMap(([operation, entry]) =>
      entry.status !== "wrapped"
        ? []
        : entry.by.length === 0
          ? [`${operation}: empty by`]
          : entry.by.filter((cmux) => !cmuxOps.has(cmux)).map((cmux) => `${operation}: ${cmux} is not in openapi.json`),
    );
    expect(broken).toEqual([]);
  });

  it("gives every planned operation a task and every denied operation a reason", () => {
    const broken = Object.entries(coverage.operations).flatMap(([operation, entry]) => {
      switch (entry.status) {
        case "wrapped":
          return [];
        case "planned":
          return BEAD.test(entry.bead) && entry.reason === `planned in ${entry.bead}` ? [] : [`${operation}: planned needs a bead and "planned in <bead>"`];
        case "denied":
          return entry.reason.length >= 40 && !/planned/i.test(entry.reason) ? [] : [`${operation}: denied needs a real reason`];
        default:
          return [`${operation}: unknown status`];
      }
    });
    expect(broken).toEqual([]);
  });
});

describe("upstream SDK and CLI coverage", () => {
  const checkSurface = (kind: "sdk" | "cli", names: string[]) => {
    const entries = coverage[kind];
    const missing = names.filter((name) => !(name in entries));
    const stale = Object.keys(entries).filter((name) => !names.includes(name));
    const broken = Object.entries(entries).flatMap(([name, entry]) => {
      if ("operations" in entry) {
        return entry.operations.length === 0
          ? [`${name}: no operations`]
          : entry.operations.filter((operation) => !(operation in coverage.operations)).map((operation) => `${name}: unknown ${operation}`);
      }
      return entry.reason.length >= 20 ? [] : [`${name}: needs a reason`];
    });
    expect({ missing, stale, broken }).toEqual({ missing: [], stale: [], broken: [] });
  };

  it("maps every public SDK method", () => {
    const methods = sdkMethods();
    expect(methods.length).toBeGreaterThan(50);
    checkSurface("sdk", methods);
  });

  it("maps every CLI command", () => {
    const commands = cliCommands();
    expect(commands.length).toBeGreaterThan(5);
    checkSurface("cli", commands);
  });
});

describe("coverage report", () => {
  it("summarizes the states (printed for CI logs)", () => {
    const counts: Record<string, number> = {};
    for (const entry of Object.values(coverage.operations)) {
      const key = entry.status === "planned" ? `planned:${entry.bead}` : entry.status;
      counts[key] = (counts[key] ?? 0) + 1;
    }
    console.log(`upstream coverage: ${JSON.stringify(counts)}`);
    expect(Object.values(counts).reduce((sum, count) => sum + count, 0)).toBe(upstreamOps.length);
  });
});
