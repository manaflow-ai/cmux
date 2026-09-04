import { describe, expect, test } from "bun:test";
import {
  authenticateRequestRouteToken,
  ROUTE_TOKEN_HEADER,
  routeTokenFromRequest,
  VM_ID_HEADER,
  VM_PLACEHOLDER_API_KEY,
} from "../services/coderouter/routeTokenAuth";

function request(headers: Record<string, string>): Request {
  return new Request("https://coderouter.dev/v1/responses", { headers });
}

const principals: Record<string, { teamId: string; stackUserId: string; vmId: string | null }> = {
  crt_cli: { teamId: "team-1", stackUserId: "user-1", vmId: null },
  crt_vm: { teamId: "team-1", stackUserId: "user-1", vmId: "vm-1" },
};

async function authenticate(token: string) {
  return principals[token] ?? null;
}

describe("route token extraction", () => {
  test("prefers the edge-injected header over Authorization and x-api-key", () => {
    expect(routeTokenFromRequest(request({
      [ROUTE_TOKEN_HEADER]: " crt_edge ",
      authorization: "Bearer crt_bearer",
      "x-api-key": "crt_apikey",
    }))).toBe("crt_edge");
    expect(routeTokenFromRequest(request({
      authorization: "bearer\tcrt_bearer",
      "x-api-key": "crt_apikey",
    }))).toBe("crt_bearer");
    expect(routeTokenFromRequest(request({ "x-api-key": "crt_apikey" })))
      .toBe("crt_apikey");
    expect(routeTokenFromRequest(request({}))).toBeNull();
    expect(routeTokenFromRequest(request({ authorization: "Basic abc" }))).toBeNull();
  });

  test("the placeholder key is never a credential", () => {
    expect(routeTokenFromRequest(request({
      authorization: `Bearer ${VM_PLACEHOLDER_API_KEY}`,
    }))).toBeNull();
    expect(routeTokenFromRequest(request({
      "x-api-key": VM_PLACEHOLDER_API_KEY,
    }))).toBeNull();
    expect(routeTokenFromRequest(request({
      authorization: `Bearer ${VM_PLACEHOLDER_API_KEY}`,
      "x-api-key": VM_PLACEHOLDER_API_KEY,
      [VM_ID_HEADER]: "vm-1",
    }))).toBeNull();
    // The placeholder next to a real credential does not mask it.
    expect(routeTokenFromRequest(request({
      authorization: `Bearer ${VM_PLACEHOLDER_API_KEY}`,
      "x-api-key": "crt_apikey",
    }))).toBe("crt_apikey");
  });
});

describe("route token request authentication", () => {
  test("reports a missing token without a lookup", async () => {
    let lookups = 0;
    const result = await authenticateRequestRouteToken(
      request({ authorization: `Bearer ${VM_PLACEHOLDER_API_KEY}` }),
      async (token) => {
        lookups++;
        return authenticate(token);
      },
    );
    expect(result).toEqual({ ok: false, reason: "missing_route_token" });
    expect(lookups).toBe(0);
  });

  test("reports an unknown token", async () => {
    const result = await authenticateRequestRouteToken(
      request({ authorization: "Bearer crt_unknown" }),
      authenticate,
    );
    expect(result).toEqual({ ok: false, reason: "invalid_route_token" });
  });

  test("an unbound token ignores x-cmux-vm-id", async () => {
    const withHeader = await authenticateRequestRouteToken(
      request({ authorization: "Bearer crt_cli", [VM_ID_HEADER]: "vm-9" }),
      authenticate,
    );
    const withoutHeader = await authenticateRequestRouteToken(
      request({ authorization: "Bearer crt_cli" }),
      authenticate,
    );
    const expected = {
      ok: true,
      identity: { teamId: "team-1", stackUserId: "user-1", vmId: null, token: "crt_cli" },
    };
    expect(withHeader).toEqual(expected);
    expect(withoutHeader).toEqual(expected);
  });

  test("a bound token requires the exact x-cmux-vm-id", async () => {
    const matched = await authenticateRequestRouteToken(
      request({ [ROUTE_TOKEN_HEADER]: "crt_vm", [VM_ID_HEADER]: " vm-1 " }),
      authenticate,
    );
    expect(matched).toEqual({
      ok: true,
      identity: { teamId: "team-1", stackUserId: "user-1", vmId: "vm-1", token: "crt_vm" },
    });
    const rejected: Record<string, string>[] = [
      { [ROUTE_TOKEN_HEADER]: "crt_vm" },
      { [ROUTE_TOKEN_HEADER]: "crt_vm", [VM_ID_HEADER]: "" },
      { [ROUTE_TOKEN_HEADER]: "crt_vm", [VM_ID_HEADER]: "vm-2" },
      { [ROUTE_TOKEN_HEADER]: "crt_vm", [VM_ID_HEADER]: "VM-1" },
    ];
    for (const headers of rejected) {
      expect(await authenticateRequestRouteToken(request(headers), authenticate))
        .toEqual({ ok: false, reason: "vm_mismatch" });
    }
  });

  test("a legacy principal without vmId is treated as unbound", async () => {
    const result = await authenticateRequestRouteToken(
      request({ authorization: "Bearer crt_legacy", [VM_ID_HEADER]: "vm-1" }),
      async () => ({ teamId: "team-1", stackUserId: "user-1" }),
    );
    expect(result).toMatchObject({ ok: true, identity: { vmId: null } });
  });
});
