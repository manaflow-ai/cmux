import { describe, expect, mock, test } from "bun:test";

// A signed-in user who opens a team invite link while Stack is throttled used
// to be redirected to sign-in, as if signed out (and sign-in sends a signed-in
// user straight back). A Stack outage must show the retry state instead.

class DashboardSessionMissingError extends Error {
  override readonly name = "DashboardSessionMissingError";
}
class DashboardSessionUnavailableError extends Error {
  override readonly name = "DashboardSessionUnavailableError";
}

let nextRead: () => Promise<unknown> = async () => ({ id: "user-1", primaryEmail: "user@example.com" });
mock.module("../app/lib/dashboard-session", () => ({
  DashboardSessionMissingError,
  DashboardSessionUnavailableError,
  readDashboardSessionUser: () => nextRead(),
}));
mock.module("../app/lib/stack", () => ({
  isStackConfigured: () => true,
  getStackServerApp: () => ({}),
}));

const { readJoinViewer } = await import("../app/lib/dashboard-auth");
const { localizedVaultPath, vaultSignInHref } = await import("../app/lib/vault-auth");
const { joinPageOutcome } = await import("../app/[locale]/join/[token]/join-outcome");

describe("join link viewer", () => {
  test("a Stack throttle for a signed-in user is a retry, never a sign-in redirect", async () => {
    nextRead = async () => {
      throw new DashboardSessionUnavailableError("Dashboard Stack authorization unavailable", {
        cause: Object.assign(new Error("Stack Auth rate limited"), { status: 429 }),
      });
    };
    const viewer = await readJoinViewer();
    expect(viewer).toEqual({ kind: "unavailable" });
    expect(joinPageOutcome(viewer, "ja", "tok en")).toEqual({ kind: "retry", retryHref: "/ja/join/tok%20en" });
  });

  test("an error that lost its prototype crossing the cache is also a retry", async () => {
    nextRead = async () => { throw new Error("Dashboard Stack authorization unavailable"); };
    expect(await readJoinViewer()).toEqual({ kind: "unavailable" });
  });

  test("a missing session still signs the visitor in and returns to the link", async () => {
    nextRead = async () => { throw new DashboardSessionMissingError("No dashboard session cookie"); };
    const viewer = await readJoinViewer();
    expect(viewer).toEqual({ kind: "signed_out" });
    expect(joinPageOutcome(viewer, "en", "abc")).toEqual({
      kind: "sign_in",
      href: vaultSignInHref(localizedVaultPath("en", "/join/abc")),
    });
  });

  test("a signed-in user renders the invite", async () => {
    nextRead = async () => ({ id: "user-1", primaryEmail: "user@example.com" });
    const viewer = await readJoinViewer();
    expect(joinPageOutcome(viewer, "en", "abc")).toEqual({
      kind: "render",
      user: { id: "user-1", primaryEmail: "user@example.com" },
    });
  });
});
