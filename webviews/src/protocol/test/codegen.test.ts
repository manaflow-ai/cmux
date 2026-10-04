import { describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { createMockPair } from "../adapters/mock";
import { generate } from "../codegen/generate";
import { ProtocolError, ProtocolErrorCode } from "../errors";
import { createClient, IR_VERSION, OPS } from "../generated/client";
import {
  isGitStatus,
  schema,
  validateGitDiffParams,
  validateGitStatus,
  validateGitStatusParams,
} from "../generated/validators";
import { Session } from "../session";

const protocolRoot = path.resolve(import.meta.dir, "..");
const seedPath = path.join(protocolRoot, "ir/pane-protocol.seed.json");
const seed: unknown = JSON.parse(readFileSync(seedPath, "utf8"));

describe("codegen against the seed IR", () => {
  test("committed generated files match a fresh generation (the --check contract)", () => {
    const files = generate(seed, { source: "webviews/src/protocol/ir/pane-protocol.seed.json" });
    for (const [name, content] of Object.entries(files)) {
      expect(readFileSync(path.join(protocolRoot, "generated", name), "utf8")).toBe(content);
    }
  });

  test("one client method per op, grouped by namespace, plus typed events", () => {
    const [a] = createMockPair();
    const client = createClient(new Session(a, { role: "client" }));
    expect(typeof client.cmux.git.status).toBe("function");
    expect(typeof client.cmux.git.diff).toBe("function");
    expect(typeof client.com.example.hello.greet.say).toBe("function");
    expect(typeof client.cmux.git.events.statusChanged).toBe("function");
    expect(IR_VERSION).toBe("0.1.0");
    expect(OPS.map((op) => op.name)).toEqual(["cmux.git.status", "cmux.git.diff", "com.example.hello.greet.say"]);
  });

  test("generated client + schema over a session: valid result passes, invalid result is refused", async () => {
    const [a, b] = createMockPair();
    const client = createClient(new Session(a, { role: "client", schema }));
    const server = new Session(b, { role: "server", schema });
    let branch: unknown = "main";
    server.register("cmux.git.status", () => ({ branch, files: [{ path: "a.ts", index: "M", worktree: " " }] }));
    await expect(client.cmux.git.status({ cwd: "/repo" })).resolves.toEqual({
      branch: "main",
      files: [{ path: "a.ts", index: "M", worktree: " " }],
    });
    branch = 7;
    const error = await client.cmux.git.status({ cwd: "/repo" }).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ProtocolError);
    expect(error).toMatchObject({ code: ProtocolErrorCode.invalidResult });
    expect((error as ProtocolError).message).toContain("/branch: expected string or null");
  });

  test("the provider side refuses params outside the schema", async () => {
    const [a, b] = createMockPair();
    const client = createClient(new Session(a, { role: "client" }));
    const server = new Session(b, { role: "server", schema });
    server.register("cmux.git.status", () => ({ branch: null, files: [] }));
    // @ts-expect-error cwd is required by the generated type
    await expect(client.cmux.git.status({})).rejects.toMatchObject({ code: ProtocolErrorCode.invalidParams });
  });

  test("typed events are validated too", async () => {
    const [a, b] = createMockPair();
    const client = createClient(new Session(a, { role: "client", schema }));
    const server = new Session(b, { role: "server" });
    server.provide("cmux.git.status.changed", (ctx) => {
      ctx.emit({ branch: "main", files: [] });
      ctx.emit({ branch: "main" });
    });
    const events: unknown[] = [];
    let invalid = 0;
    await client.cmux.git.events.statusChanged({ onEvent: (data) => events.push(data), onInvalid: () => invalid++ });
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(events).toEqual([{ branch: "main", files: [] }]);
    expect(invalid).toBe(1);
  });
});

describe("generated validators", () => {
  test("pass", () => {
    expect(validateGitStatusParams({ cwd: "/r" })).toEqual([]);
    expect(validateGitDiffParams({ cwd: "/r", base: null, include_patch: true })).toEqual([]);
    expect(isGitStatus({ branch: null, files: [] })).toBe(true);
  });

  test("fail with JSON-pointer paths", () => {
    expect(validateGitStatusParams({})).toEqual([{ path: "", message: 'missing required property "cwd"' }]);
    expect(validateGitStatusParams({ cwd: "/r", extra: 1 })).toEqual([
      { path: "", message: 'unexpected property "extra"' },
    ]);
    expect(validateGitStatusParams(null)).toEqual([{ path: "", message: "expected object" }]);
    expect(validateGitStatusParams([])).toEqual([{ path: "", message: "expected object" }]);
    expect(validateGitStatus({ branch: "m", files: [{ path: "a", index: "M" }, 3] })).toEqual([
      { path: "/files/0", message: 'missing required property "worktree"' },
      { path: "/files/1", message: "expected object" },
    ]);
    expect(validateGitDiffParams({ cwd: "/r", include_patch: "yes" })).toEqual([
      { path: "/include_patch", message: "expected boolean" },
    ]);
  });

  test("schema returns null for names outside the IR", () => {
    expect(schema.validateParams("cmux.git.nope", {})).toBeNull();
    expect(schema.validateResult("cmux.git.status", { branch: null, files: [] })).toEqual([]);
    expect(schema.validateEvent("cmux.git.status.changed", {})).toHaveLength(2);
  });

  test("a __proto__ key cannot reach a validator table", () => {
    expect(schema.validateParams("__proto__", {})).toBeNull();
    expect(schema.validateParams("constructor", {})).toBeNull();
  });
});

describe("JSON Schema subset beyond the seed", () => {
  const ir = {
    version: "9.9.9",
    namespaces: [{ name: "cmux", owner: "first-party" }],
    ops: [
      {
        name: "cmux.sample.run",
        kind: "mutation",
        scope: "sample:write",
        params: {
          type: "object",
          properties: {
            mode: { enum: ["fast", "slow"] },
            count: { type: "integer", format: "uint32", minimum: 0 },
            ratio: { type: "number", exclusiveMaximum: 1 },
            tag: { type: "string", pattern: "^[a-z]+$", minLength: 2, maxLength: 4 },
            target: { anyOf: [{ $ref: "#/types/Target" }, { type: "null" }] },
            kind: { oneOf: [{ const: "a" }, { const: "b" }] },
            labels: { type: "object", additionalProperties: { type: "string" } },
            items: { type: "array", items: { type: "string" }, minItems: 1, maxItems: 2 },
          },
          required: ["mode"],
          additionalProperties: false,
        },
        result: { type: "null" },
        errors: [],
      },
    ],
    events: [],
    interfaces: [],
    types: {
      Target: { type: "object", properties: { id: { type: "string" } }, required: ["id"] },
    },
  };

  async function load() {
    const files = generate(ir, { source: "test" });
    const dir = mkdtempSync(path.join(os.tmpdir(), "pane-protocol-codegen-"));
    for (const [name, content] of Object.entries(files)) writeFileSync(path.join(dir, name), content);
    return { files, mod: (await import(path.join(dir, "validators.ts"))) as Record<string, (v: unknown) => unknown> };
  }

  test("types render enums, unions, records and inline op types", async () => {
    const { files } = await load();
    expect(files["types.ts"]).toContain('mode: "fast" | "slow";');
    expect(files["types.ts"]).toContain("target?: (Target | null);");
    expect(files["types.ts"]).toContain("labels?: Record<string, string>;");
    expect(files["types.ts"]).toContain("export interface CmuxSampleRunParams {");
    expect(files["types.ts"]).toContain("export type CmuxSampleRunResult = null;");
  });

  test("validators enforce every supported keyword", async () => {
    const { mod } = await load();
    const check = mod.validateCmuxSampleRunParams as (v: unknown) => Array<{ path: string; message: string }>;
    expect(
      check({
        mode: "fast",
        count: 3,
        ratio: 0.5,
        tag: "ab",
        target: { id: "x" },
        kind: "a",
        labels: { a: "b" },
        items: ["x"],
      }),
    ).toEqual([]);
    expect(check({ mode: "fast", target: null })).toEqual([]);
    const messages = (value: unknown) => check(value).map((issue) => `${issue.path} ${issue.message}`);
    expect(messages({ mode: "medium" })).toEqual(['/mode expected one of ["fast","slow"]']);
    expect(messages({ mode: "fast", count: -1 })).toEqual(["/count less than 0", "/count not a valid uint32"]);
    expect(messages({ mode: "fast", count: 1.5 })).toEqual(["/count expected integer"]);
    expect(messages({ mode: "fast", count: 2 ** 32 })).toEqual(["/count not a valid uint32"]);
    expect(messages({ mode: "fast", ratio: 1 })).toEqual(["/ratio not less than 1"]);
    expect(messages({ mode: "fast", tag: "A" })).toEqual(["/tag shorter than 2", "/tag does not match ^[a-z]+$"]);
    expect(messages({ mode: "fast", tag: "abcde" })).toEqual(["/tag longer than 4"]);
    expect(messages({ mode: "fast", target: { nope: 1 } })).toEqual(["/target did not match any of 2 schemas"]);
    expect(messages({ mode: "fast", kind: "c" })).toEqual(["/kind matched 0 of 2 schemas, expected exactly one"]);
    expect(messages({ mode: "fast", labels: { "a/b": 1 } })).toEqual(["/labels/a~1b expected string"]);
    expect(messages({ mode: "fast", items: [] })).toEqual(["/items fewer than 1 items"]);
    expect(messages({ mode: "fast", items: ["a", "b", 3] })).toEqual([
      "/items more than 2 items",
      "/items/2 expected string",
    ]);
  });

  test("unsupported keywords and bad names fail the codegen", () => {
    const withKeyword = { ...structuredClone(ir), types: { Target: { type: "object", patternProperties: {} } } };
    expect(() => generate(withKeyword, { source: "t" })).toThrow('keyword "patternProperties"');

    const outside = structuredClone(ir);
    outside.ops[0].name = "com.acme.thing.run";
    expect(() => generate(outside, { source: "t" })).toThrow("outside every declared namespace");

    const badRef = structuredClone(ir);
    (badRef.ops[0] as { result: unknown }).result = { $ref: "#/types/Missing" };
    expect(() => generate(badRef, { source: "t" })).toThrow("unknown type Missing");

    const shape = structuredClone(ir);
    shape.ops[0].name = "cmux.sample";
    expect(() => generate(shape, { source: "t" })).toThrow("<namespace>.<family>.<verb>");
  });
});
