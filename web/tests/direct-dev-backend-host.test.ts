import { describe, expect, test } from "bun:test";
import { shouldTrustDirectDevBackendHost } from "../app/lib/direct-dev-backend-host";

describe("direct dev backend host forwarding", () => {
  test("trusts the forwarded host only for the direct backend transport", () => {
    expect(
      shouldTrustDirectDevBackendHost({
        CMUX_DEV_BACKEND_TRANSPORT: "direct",
      }),
    ).toBe(true);
  });

  test("does not trust the forwarded host for the SSH transport", () => {
    expect(
      shouldTrustDirectDevBackendHost({
        CMUX_DEV_BACKEND_TRANSPORT: "ssh",
      }),
    ).toBe(false);
  });

  test("does not trust a missing or malformed transport value", () => {
    expect(shouldTrustDirectDevBackendHost({})).toBe(false);
    expect(
      shouldTrustDirectDevBackendHost({ CMUX_DEV_BACKEND_TRANSPORT: "DIRECT " }),
    ).toBe(false);
  });
});
