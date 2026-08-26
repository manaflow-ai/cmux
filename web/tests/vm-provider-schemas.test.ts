import { describe, expect, test } from "bun:test";
import {
  BlaxelPreviewListSchema,
  BlaxelProcessSchema,
  BlaxelSandboxSchema,
  parseFreestyleExecResponse,
  parseProviderJson,
} from "../services/vms/drivers/schemas";
import { ProviderError } from "../services/vms/drivers/types";

describe("parseProviderJson", () => {
  test("returns the validated payload", () => {
    const sandbox = parseProviderJson("blaxel", "GET /sandboxes/x", BlaxelSandboxSchema, {
      metadata: { name: "noble-wren", url: "https://sandbox.example.dev" },
      status: "DEPLOYED",
      unknownField: "passes through validation and is dropped",
    });
    expect(sandbox.metadata?.name).toBe("noble-wren");
    expect(sandbox.status).toBe("DEPLOYED");
  });

  test("wraps a shape mismatch in a ProviderError naming the operation", () => {
    expect(() =>
      parseProviderJson("blaxel", "GET /sandboxes/x", BlaxelSandboxSchema, "not an object"),
    ).toThrow(ProviderError);
    expect(() =>
      parseProviderJson("blaxel", "GET /sandboxes/x", BlaxelSandboxSchema, "not an object"),
    ).toThrow(/GET \/sandboxes\/x returned an unexpected response shape/);
  });

  test("an empty body fails validation for operations that expect one", () => {
    expect(() =>
      parseProviderJson("blaxel", "POST /sandboxes", BlaxelSandboxSchema, undefined),
    ).toThrow(ProviderError);
  });
});

describe("Blaxel schemas", () => {
  test("process responses keep the exit code and streams", () => {
    const process = BlaxelProcessSchema.parse({
      status: "completed",
      exitCode: 3,
      stdout: "out",
      stderr: "err",
    });
    expect(process.exitCode).toBe(3);
    expect(process.stdout).toBe("out");
  });

  test("a stringly-typed exitCode is rejected instead of propagating", () => {
    expect(BlaxelProcessSchema.safeParse({ exitCode: "0" }).success).toBe(false);
  });

  test("preview lists accept both bare arrays and {items}, skipping malformed entries", () => {
    const bare = BlaxelPreviewListSchema.parse([
      { metadata: { name: "cmuxd" }, spec: { url: "https://a" } },
      "garbage",
      42,
    ]);
    expect(bare.map((preview) => preview.metadata?.name)).toEqual(["cmuxd"]);

    const wrapped = BlaxelPreviewListSchema.parse({
      items: [{ metadata: { name: "port-3000" } }],
    });
    expect(wrapped[0]?.metadata?.name).toBe("port-3000");

    expect(BlaxelPreviewListSchema.parse({})).toEqual([]);
  });
});

describe("parseFreestyleExecResponse", () => {
  test("maps statusCode to exitCode and normalizes null streams", () => {
    expect(parseFreestyleExecResponse("exec", { statusCode: 2, stdout: null, stderr: "boom" })).toEqual({
      exitCode: 2,
      stdout: "",
      stderr: "boom",
    });
  });

  test("a missing statusCode is a ProviderError, never exit-0 success", () => {
    expect(() => parseFreestyleExecResponse("exec(vm-1)", { stdout: "looks fine" })).toThrow(
      ProviderError,
    );
    expect(() => parseFreestyleExecResponse("exec(vm-1)", { stdout: "looks fine" })).toThrow(
      /exec\(vm-1\) returned an unexpected response shape/,
    );
  });

  test("a non-numeric statusCode is rejected", () => {
    expect(() => parseFreestyleExecResponse("exec", { statusCode: "0" })).toThrow(ProviderError);
  });
});
