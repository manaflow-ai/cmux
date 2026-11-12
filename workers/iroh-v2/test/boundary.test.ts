import { expect, test } from "bun:test";
import { decodeJSON, encodeResponse, httpFailure, inputOperation, parseControlRequest, readBoundedBody } from "../src/boundary";
import { ErrorResponseSchema, type ControlResponse } from "../src/contracts/responses";
import { OperationError } from "../src/errors";

test("a body without Content-Length is cancelled as soon as its byte budget is exceeded", async () => {
  let cancelled = false;
  const body = new ReadableStream<Uint8Array>({
    pull(controller) { controller.enqueue(new Uint8Array(6000)); },
    cancel() { cancelled = true; },
  });
  await expect(readBoundedBody(new Response(body), 10_000)).rejects.toMatchObject({ code: "payload_too_large", status: 413 });
  expect(cancelled).toBe(true);
  expect(() => decodeJSON(new Uint8Array([0xff]))).toThrow("invalid_request");
});

test("known malformed methods share their method allowance and arbitrary names cannot allocate counters", () => {
  expect(inputOperation({ schemaId: "device.register.v1", malicious: true })).toBe("device.register");
  for (const schemaId of ["__proto__", "constructor", "made-up-device-123"]) {
    expect(inputOperation({ schemaId })).toBe("input.rejected");
    expect(() => parseControlRequest({ schemaId })).toThrow("unsupported_method");
  }
  expect(() => parseControlRequest({ schemaId: "device.register.v1" })).toThrow("invalid_request");
});

test("retirement returns a long retry window with matching HTTP and typed error", async () => {
  let error: unknown;
  try { parseControlRequest({ schemaId: "retired.request.v1" }, new Set(["retired.request.v1"])); }
  catch (failure) { error = failure; }
  const response = httpFailure(error, "request-1");
  expect(response.status).toBe(426);
  expect(response.headers.get("retry-after")).toBe("3600");
  expect(ErrorResponseSchema.parse(await response.json())).toEqual({
    schemaId: "error.v1", requestId: "request-1", code: "client_upgrade_required", retryable: true, retryAfterMs: 3_600_000,
  });
});

test("invalid server output is rejected and unexpected exceptions reveal no internal data", async () => {
  expect(() => encodeResponse({ schemaId: "operation.completed.v1", requestId: "r", revision: -1 } as ControlResponse))
    .toThrow("internal_error");
  expect(() => encodeResponse({ schemaId: "operation.completed.v1", requestId: "r", revision: 1, leaked: "private" } as ControlResponse))
    .toThrow("internal_error");
  const response = httpFailure(new Error("secret SQL parameter"));
  expect(response.status).toBe(500);
  expect(await response.text()).not.toContain("secret");
  const limit = httpFailure(new OperationError("rate_limited", 429, true, 1500), "r");
  expect(limit.headers.get("retry-after")).toBe("2");
});
