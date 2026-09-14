import { describe, expect, test } from "bun:test";
import { freestyleGuestFixture, guestCreateOptions } from "./fixtures/freestyleGuest";

describe("Freestyle guest install result contract (SDK 0.2.10)", () => {
  test("a reported zero exit publishes a ready machine", async () => {
    const fixture = freestyleGuestFixture();
    const handle = await fixture.provider.create(guestCreateOptions);
    expect(handle.status).toBe("running");
    expect(fixture.liveVms.size).toBe(1);
    expect(fixture.allocations()).toBe(1);
  });

  // The incident preserved only the old 'exited 124' message. These are
  // synthetic candidate responses, not invented copies of the lost body.
  test.each([
    [{ stdout: "", stderr: "" }, "missing_status", undefined],
    [{ statusCode: null, stdout: "", stderr: "" }, "provider_timeout", null],
    [{ statusCode: 124, stderr: "synthetic guest exit" }, "guest_exit", 124],
    [{ statusCode: 1, stderr: "synthetic rename failure" }, "guest_exit", 1],
    [{ statusCode: "0" }, "invalid_status", undefined],
  ])("preserves outcome %s without a false ready result", async (body, outcome, statusCode) => {
    const fixture = freestyleGuestFixture({ exec: async () => Response.json(body) });
    const error = await fixture.provider.create(guestCreateOptions).catch((error: unknown) => error);
    expect(error).toMatchObject({
      name: "ProviderError",
      cause: { name: "GuestCliInstallError", outcome, statusCode },
    });
    expect(fixture.allocations()).toBe(1);
    expect(fixture.liveVms.size).toBe(0);
    expect(fixture.removals).toEqual(fixture.writes);
  });

  test.each([
    ["AbortError", "cancelled"],
    ["TimeoutError", "transport_timeout"],
  ])("preserves transport %s separately from a guest exit", async (name, outcome) => {
    const cause = new DOMException("synthetic transport interruption", name);
    const fixture = freestyleGuestFixture({ exec: async () => { throw cause; } });
    const error = await fixture.provider.create(guestCreateOptions).catch((error: unknown) => error);
    expect(error).toMatchObject({ cause: { name: "GuestCliInstallError", outcome, cause } });
    expect(fixture.liveVms.size).toBe(0);
    expect(fixture.removals).toEqual(fixture.writes);
  });

  test("failed rollback retains the allocated machine and both failures", async () => {
    const fixture = freestyleGuestFixture({
      exec: async () => Response.json({ statusCode: 1, stderr: "synthetic install failure" }),
      deleteFailure: true,
    });
    const error = await fixture.provider.create(guestCreateOptions).catch((error: unknown) => error);
    expect(error).toMatchObject({
      name: "ProviderCreateCleanupError",
      providerVmId: "vm-fixture-1",
      cause: { name: "GuestCliInstallError", outcome: "guest_exit", statusCode: 1 },
      cleanupCause: { name: "FreestyleApiError", status: 503 },
    });
    expect(fixture.liveVms.size).toBe(1);
  });
});
