import { describe, expect, test } from "bun:test";
import { FreestyleApiError } from "freestyle";
import { ProviderError } from "../services/vms/drivers/types";
import {
  isProviderIdentityNotFoundError,
  isProviderNotFoundError,
} from "../services/vms/providerErrors";

describe("provider error classification", () => {
  test.each([401, 403, 429, 500, 502, 503, 504])("HTTP %s takes precedence over wrapped missing-resource diagnostics", (status) => {
    const error = new ProviderError("freestyle", "VM not found while reading stats", new FreestyleApiError(
      status, { code: "INTERNAL", message: "VM not found in upstream cache" },
    ));
    expect(isProviderNotFoundError(error)).toBe(false);
  });

  test("nested structured status takes precedence over a conflicting not-found code", () => {
    const error = { code: "NOT_FOUND", cause: { response: { status: 502 } } };
    expect(isProviderNotFoundError(error)).toBe(false);
    expect(isProviderNotFoundError({ code: "NOT_FOUND" })).toBe(true);
    expect(isProviderNotFoundError({ cause: { statusCode: 404 } })).toBe(true);
  });

  test.each([
    { status: 0, response: { status: 502 } },
    { status: 600, response: { status: 503 } },
    { status: -1, statusCode: 502 },
  ])("ignores invalid status sentinels before selecting a retryable HTTP status: %j", (error) => {
    expect(isProviderNotFoundError({ ...error, message: "VM not found while reading stats" })).toBe(false);
  });

  test("keeps identity deletion errors out of VM not-found classification", () => {
    expect(isProviderNotFoundError(new Error("identity does not exist"))).toBe(false);
    expect(isProviderIdentityNotFoundError(new Error("identity does not exist"))).toBe(true);
  });

  test("keeps VM deletion errors in VM not-found classification", () => {
    expect(isProviderNotFoundError(new Error("VM does not exist"))).toBe(true);
    expect(isProviderNotFoundError(new Error("sandbox has been deleted"))).toBe(true);
  });

  test("recognizes provider identity missing errors in nested response bodies", () => {
    const err = {
      response: {
        data: {
          error: "requested credential was not found",
        },
      },
    };

    expect(isProviderIdentityNotFoundError(err)).toBe(true);
    expect(isProviderNotFoundError(err)).toBe(false);
  });
});
