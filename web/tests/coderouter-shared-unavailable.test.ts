import { describe, expect, test } from "bun:test";
import { sharedAccountsFailureState } from "../services/coderouter/dashboardOverview";
import { createHostedSubrouterClient, HostedSubrouterError, HostedSubrouterUnreachableError } from "../services/subrouter/hostedClient";

// Regression: with sr.cmux.com gone from DNS, the dashboard said "Some
// accounts could not load ... Try again shortly" forever and logged nothing.
describe("shared accounts when the hosted service cannot be reached", () => {
  test("a network failure is an unreachable error, distinct from an HTTP refusal", async () => {
    const client = createHostedSubrouterClient({
      baseUrl: "https://sr.example.test",
      fetch: (async () => { throw new TypeError("fetch failed: getaddrinfo ENOTFOUND sr.example.test"); }) as unknown as typeof fetch,
    });
    const error = await client.listAccounts("tenant").catch((caught: unknown) => caught);
    expect(error).toBeInstanceOf(HostedSubrouterUnreachableError);
    expect(error).toBeInstanceOf(HostedSubrouterError);
  });

  test("unreachable maps to its own state; anything else stays a load error", () => {
    expect(sharedAccountsFailureState(new HostedSubrouterUnreachableError())).toEqual({ kind: "unavailable" });
    expect(sharedAccountsFailureState(new HostedSubrouterError("hosted Subrouter request failed", 500))).toEqual({ kind: "error" });
    expect(sharedAccountsFailureState(new Error("boom"))).toEqual({ kind: "error" });
  });
});
