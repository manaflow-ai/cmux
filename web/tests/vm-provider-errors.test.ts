import { describe, expect, test } from "bun:test";
import {
  isProviderIdentityNotFoundError,
  isProviderNotFoundError,
} from "../services/vms/providerErrors";

describe("provider error classification", () => {
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
