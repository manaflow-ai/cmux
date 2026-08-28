import { describe, expect, test } from "bun:test";
import {
  capabilityList,
  idempotencyKeyFromRequest,
  MAX_OBJECT_BODY_BYTES,
  optionalClientIdentifier,
  optionalString,
  parseLenientObjectBody,
  parseOptionalObjectBody,
  parseRequiredObjectBody,
  providerField,
  stringField,
} from "../services/vms/routeInput";
import { VmFreeAccessExpiredError, VmNotFoundError } from "../services/vms/errors";
import {
  vmCreateLikeErrorResponse,
  vmResourceErrorResponse,
} from "../services/vms/routeHelpers";

async function responseBody(response: Response): Promise<Record<string, unknown>> {
  return await response.json() as Record<string, unknown>;
}

describe("Cloud VM route input", () => {
  test("parses optional object bodies and keeps operation-specific validation messages", async () => {
    const empty = await parseOptionalObjectBody(new Request("https://cmux.test"), {
      operation: "fork",
      action: "Send `{}`.",
    });
    expect(empty).toEqual({ ok: true, body: {} });

    const valid = await parseOptionalObjectBody(new Request("https://cmux.test", {
      method: "POST",
      body: JSON.stringify({ name: " agent " }),
    }), { operation: "fork", action: "Send `{}`." });
    expect(valid).toEqual({ ok: true, body: { name: " agent " } });

    const malformed = await parseOptionalObjectBody(new Request("https://cmux.test", {
      method: "POST",
      body: "{",
    }), { operation: "snapshot", action: "Send `{}`." });
    expect(malformed.ok).toBe(false);
    if (!malformed.ok) {
      expect(malformed.response.status).toBe(400);
      expect((await responseBody(malformed.response)).message).toBe("Cloud VM snapshot expected valid JSON.");
    }

    const array = await parseOptionalObjectBody(new Request("https://cmux.test", {
      method: "POST",
      body: "[]",
    }), { operation: "snapshot", action: "Send `{}`." });
    expect(array.ok).toBe(false);
    if (!array.ok) expect((await responseBody(array.response)).error).toBe("vm_expected_object");
  });

  test("preserves required-body empty handling and lenient legacy handling", async () => {
    const required = await parseRequiredObjectBody(new Request("https://cmux.test"), {
      operation: "restore",
      action: "Send `{ \"snapshotId\": \"...\" }`.",
    });
    expect(required).toEqual({ ok: true, body: null });

    const malformed = await parseLenientObjectBody(new Request("https://cmux.test", {
      method: "POST",
      body: "not-json",
    }), { operation: "attach", action: "Send a JSON object." });
    expect(malformed).toEqual({ ok: true, body: {} });

    const primitive = await parseLenientObjectBody(new Request("https://cmux.test", {
      method: "POST",
      body: "null",
    }), { operation: "attach", action: "Send a JSON object." });
    expect(primitive).toEqual({ ok: true, body: {} });
  });

  test("rejects oversized bodies before JSON parsing", async () => {
    const body = "{" + "x".repeat(MAX_OBJECT_BODY_BYTES) + "}";
    const options = { operation: "snapshot", action: "Send a smaller JSON object." };
    for (const parsed of [
      await parseOptionalObjectBody(new Request("https://cmux.test", { method: "POST", body }), options),
      await parseRequiredObjectBody(new Request("https://cmux.test", { method: "POST", body }), options),
      await parseLenientObjectBody(new Request("https://cmux.test", { method: "POST", body }), options),
    ]) {
      expect(parsed.ok).toBe(false);
      if (!parsed.ok) expect(parsed.response.status).toBe(413);
    }
  });

  test("shares field normalization and identifier validation across routes", () => {
    expect(stringField({ name: "  VM  " }, "name")).toBe("VM");
    expect(stringField({ name: 1 }, "name")).toBeUndefined();
    expect(optionalString("  title  ")).toBe("title");
    expect(optionalString("   ")).toBeNull();
    expect(optionalClientIdentifier("  pane-1  ", "sessionId")).toBe("pane-1");
    expect(() => optionalClientIdentifier("bad/value", "sessionId")).toThrow("sessionId must be");
    expect(capabilityList(["direct-ws-user-agent", " direct-ws-user-agent ", "bad/value", 3])).toEqual([
      "direct-ws-user-agent",
    ]);
  });

  test("uses the same provider allow-list for restore input and defaults", async () => {
    expect(providerField({ provider: "blaxel" })).toEqual({ ok: true, provider: "blaxel" });
    expect(providerField({})).toEqual({ ok: true });
    const invalid = providerField({ provider: "aws" });
    expect(invalid.ok).toBe(false);
    if (!invalid.ok) expect((await responseBody(invalid.response)).error).toBe("vm_invalid_provider");
  });

  test("normalizes idempotency headers once", () => {
    const key = "x".repeat(140);
    expect(idempotencyKeyFromRequest(new Request("https://cmux.test", {
      headers: { "idempotency-key": `  ${key}  ` },
    }))).toBe("x".repeat(128));
    expect(idempotencyKeyFromRequest(new Request("https://cmux.test", {
      headers: { "idempotency-key": "", "x-cmux-idempotency-key": " fallback " },
    }))).toBe("fallback");
    expect(idempotencyKeyFromRequest(new Request("https://cmux.test", {
      headers: { "idempotency-key": "   ", "x-cmux-idempotency-key": " fallback " },
    }))).toBe("fallback");
    expect(idempotencyKeyFromRequest(new Request("https://cmux.test", {
      headers: { "idempotency-key": "   ", "x-cmux-idempotency-key": "   " },
    }))).toBeUndefined();
  });
});

describe("Cloud VM route error adapters", () => {
  test("maps shared resource failures to the same response", async () => {
    const notFound = vmResourceErrorResponse(new VmNotFoundError({ vmId: "vm-1" }), "vm-1");
    expect(notFound?.status).toBe(404);
    expect((await responseBody(notFound!)).error).toBe("vm_not_found");

    const expired = vmResourceErrorResponse(
      new VmFreeAccessExpiredError({ vmId: "vm-1", windowDays: 7 }),
      "vm-1",
    );
    expect(expired?.status).toBe(402);
    expect((await responseBody(expired!)).error).toBe("vm_access_requires_pro");
  });

  test("keeps fork and restore provisioning guidance distinct", async () => {
    const error = { _tag: "VmCreateFailedError", idempotencyKey: "key" };
    const fork = vmCreateLikeErrorResponse(error, {
      operation: "fork",
      planId: "free",
      retryAction: "fork retry",
    });
    const restore = vmCreateLikeErrorResponse(error, {
      operation: "restore",
      planId: "free",
      retryAction: "restore retry",
    });
    expect((await responseBody(fork!)).message).toBe("The Cloud VM fork create attempt failed.");
    expect((await responseBody(restore!)).message).toBe("The Cloud VM restore create attempt failed.");
  });
});
