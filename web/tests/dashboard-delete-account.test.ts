import { describe, expect, test } from "bun:test";

import { AccountDeletionRequestError, deleteAccountThroughCmux } from "../dashboard-app/lib/delete-account";

type Call = { readonly url: string; readonly init: RequestInit };

function session(tokens: { accessToken: string | null; refreshToken: string | null } = { accessToken: "access", refreshToken: "refresh" }) {
  return { getAuthJson: async () => tokens };
}

function fetching(status: number, body: unknown, calls: Call[] = []) {
  return {
    calls,
    fetch: async (url: string, init: RequestInit) => {
      calls.push({ url, init });
      return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
    },
  };
}

async function failure(promise: Promise<unknown>): Promise<string> {
  try {
    await promise;
  } catch (error) {
    if (error instanceof AccountDeletionRequestError) return error.reason;
    throw error;
  }
  throw new Error("expected the deletion to fail");
}

describe("dashboard account deletion", () => {
  test("deletes through DELETE /api/account with the session's native tokens", async () => {
    const server = fetching(200, { ok: true, destroyedVms: 0 });
    await deleteAccountThroughCmux(session(), server.fetch);
    expect(server.calls).toHaveLength(1);
    const [call] = server.calls;
    expect(call!.url).toBe("/api/account");
    expect(call!.init.method).toBe("DELETE");
    const headers = new Headers(call!.init.headers);
    expect(headers.get("authorization")).toBe("Bearer access");
    expect(headers.get("x-stack-refresh-token")).toBe("refresh");
  });

  test("a deleted account whose follow-up cleanup is still running counts as deleted", async () => {
    await deleteAccountThroughCmux(session(), fetching(202, { ok: true, cleanupIncomplete: true, destroyedVms: 0 }).fetch);
  });

  test("a deletion another request is still running is not reported as done", async () => {
    expect(await failure(deleteAccountThroughCmux(session(), fetching(202, { ok: true, deletionPending: true }).fetch)))
      .toBe("pending");
  });

  test("maps refusals to reasons the dialog can explain", async () => {
    expect(await failure(deleteAccountThroughCmux(session({ accessToken: null, refreshToken: null }), fetching(200, {}).fetch)))
      .toBe("signed_out");
    expect(await failure(deleteAccountThroughCmux(session(), fetching(401, { error: "unauthorized" }).fetch))).toBe("signed_out");
    expect(await failure(deleteAccountThroughCmux(session(), fetching(503, { error: "account_delete_retryable", retryable: true }).fetch)))
      .toBe("retryable");
    expect(await failure(deleteAccountThroughCmux(session(), fetching(409, { error: "account_delete_push_delivery_in_progress" }).fetch)))
      .toBe("retryable");
    expect(await failure(deleteAccountThroughCmux(session(), fetching(500, { error: "account_delete_failed" }).fetch))).toBe("failed");
    const offline = async () => { throw new TypeError("Failed to fetch"); };
    expect(await failure(deleteAccountThroughCmux(session(), offline))).toBe("retryable");
  });
});
