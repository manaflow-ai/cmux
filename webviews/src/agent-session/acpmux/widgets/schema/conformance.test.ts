import { describe, expect, test } from "bun:test";
import settingsSchema from "../../../../../../schemas/widgets/settings.schema.json";
import bridgeVectors from "../../../../../../schemas/widgets/vectors/bridge.json";
import dataPatchVectors from "../../../../../../schemas/widgets/vectors/data-patch.json";
import digestVectors from "../../../../../../schemas/widgets/vectors/digest.json";
import policyVectors from "../../../../../../schemas/widgets/vectors/policy.json";
import recordVectors from "../../../../../../schemas/widgets/vectors/record.json";
import settingsVectors from "../../../../../../schemas/widgets/vectors/settings.json";
import tokenVectors from "../../../../../../schemas/widgets/vectors/tokens.json";
import toolVectors from "../../../../../../schemas/widgets/vectors/tools.json";
import {
  applyDataPatch,
  codeWidgetDigestMatches,
  codeWidgetsDefault,
  type PatchOperation,
  validateWidgetContract,
  widgetPolicy,
  type WidgetPolicyInput,
} from "./contract";
import { jsonEqual, SchemaSet } from "./jsonSchema";

// The shared vectors in schemas/widgets/vectors are the contract between acpmux (Rust), the Swift
// host and this pane. A value {"$fill": {"text": T, "count": N}} stands for T repeated N times.
function expand(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(expand);
  if (typeof value !== "object" || value === null) return value;
  const record = value as Record<string, unknown>;
  const keys = Object.keys(record);
  if (keys.length === 1 && keys[0] === "$fill") {
    const { text, count } = record.$fill as { text: string; count: number };
    return text.repeat(count);
  }
  const out: Record<string, unknown> = {};
  for (const key of keys)
    Object.defineProperty(out, key, {
      value: expand(record[key]),
      writable: true,
      enumerable: true,
      configurable: true,
    });
  return out;
}

type SchemaCase = { name: string; schema: string; valid: boolean; error?: "schema" | "too_large"; value: unknown };
const schemaFiles = {
  record: recordVectors,
  tools: toolVectors,
  bridge: bridgeVectors,
  tokens: tokenVectors,
  settings: settingsVectors,
};

for (const [file, vectors] of Object.entries(schemaFiles)) {
  describe(`${file} vectors`, () => {
    for (const vector of vectors.cases as SchemaCase[]) {
      test(`${vector.valid ? "accepts" : "rejects"}: ${vector.name}`, () => {
        const issues = validateWidgetContract(vector.schema, expand(vector.value));
        if (vector.valid) {
          expect(issues).toEqual([]);
        } else {
          expect(issues.length).toBeGreaterThan(0);
          expect(issues.map((issue) => issue.error)).toContain(vector.error ?? "schema");
          if (vector.error === "too_large") expect(issues.every((issue) => issue.error === "too_large")).toBe(true);
        }
      });
    }
  });
}

describe("code widget digest vectors", () => {
  for (const vector of digestVectors.cases) {
    test(vector.name, async () => {
      expect(await codeWidgetDigestMatches({ html: vector.html, sha256: vector.sha256 })).toBe(vector.matches);
    });
  }
});

type PatchCase = {
  name: string;
  before: unknown;
  patch: PatchOperation[];
  dataSchema?: string;
  after?: unknown;
  error?: { op: number; reason: string };
};

describe("dataPatch vectors", () => {
  for (const raw of dataPatchVectors.cases as PatchCase[]) {
    test(raw.name, () => {
      const vector = expand(raw) as PatchCase;
      expect(validateWidgetContract("record.schema.json#/$defs/dataPatch", vector.patch)).toEqual([]);
      const before = JSON.stringify(vector.before);
      const result = applyDataPatch(vector.before, vector.patch, vector.dataSchema);
      expect(JSON.stringify(vector.before)).toBe(before);
      if (vector.error) {
        expect(result).toEqual({ ok: false, op: vector.error.op, reason: vector.error.reason } as never);
      } else {
        expect(result.ok).toBe(true);
        const data = result.ok ? result.data : undefined;
        expect(jsonEqual(data, vector.after)).toBe(true);
        expect(JSON.stringify(data)).toBe(JSON.stringify(vector.after));
      }
    });
  }

  test("a __proto__ key never changes the prototype", () => {
    const result = applyDataPatch({}, [{ op: "set", path: "/__proto__", value: { polluted: true } }]);
    expect(result.ok).toBe(true);
    const data = (result.ok ? result.data : {}) as Record<string, unknown>;
    expect(Object.getPrototypeOf(data)).toBe(Object.prototype);
    expect(Object.keys(data)).toEqual(["__proto__"]);
    expect(({} as Record<string, unknown>).polluted).toBeUndefined();
  });
});

describe("render policy vectors", () => {
  for (const vector of policyVectors.cases) {
    const input = vector.input as WidgetPolicyInput;
    test(`${input.kind} code=${input.code} pane=${input.pane} quarantined=${input.quarantined}`, () => {
      expect(widgetPolicy(input)).toEqual(vector.expect as never);
    });
  }

  test("the code widget default comes from settings.schema.json only", () => {
    expect(codeWidgetsDefault).toBe(settingsSchema.properties["agentPane.widgets.code"].default as never);
  });
});

describe("schema loader", () => {
  test("refuses a keyword it does not implement", () => {
    expect(() => new SchemaSet([{ $id: "https://example.invalid/a.json", type: "string", format: "uri" }])).toThrow(
      /unsupported keyword format/,
    );
  });

  test("refuses an unresolved $ref", () => {
    expect(() => new SchemaSet([{ $id: "https://example.invalid/a.json", $ref: "b.json#/$defs/x" }])).toThrow(
      /unresolved \$ref/,
    );
  });
});
