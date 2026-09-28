import { beforeEach, describe, expect, mock, test } from "bun:test";

type AuthedUser = { readonly id: string };

let currentUser: AuthedUser | null = { id: "user-1" };
let accountScopeRefusal: Response | null = null;
let workflowRefusal: Response | null = null;
const listCalls: Array<{ userId: string }> = [];
const scopeCalls: string[] = [];
const devices = [{
  id: "grant-1",
  deviceId: "device-1234567890",
  name: "Studio Mac",
  reportedName: "Studio Mac",
  displayName: null,
  modelIdentifier: "Mac15,3",
  osVersion: "26.1",
  architecture: "arm64",
  cmuxVersion: "0.70.0",
  cmuxBuild: "123",
  cmuxChannel: "nightly",
  createdAt: 1_780_000_000_000,
  lastControlPlaneAt: 1_780_000_100_000,
  tunnelPurposes: ["browser", "terminal"],
}];

// Only the auth wrapper and account scope are stand-ins; the JSON helper is real.
const realRouteHelpers = { ...await import("../services/vms/routeHelpers") };
mock.module("../services/vms/routeHelpers", () => ({
  ...realRouteHelpers,
  withAuthedVmApiRoute: async (
    _request: Request,
    _route: string,
    _attributes: unknown,
    _failure: string,
    handler: (context: { user: AuthedUser }) => Promise<Response>,
  ) => currentUser
    ? handler({ user: currentUser })
    : Response.json({ error: "unauthorized" }, { status: 401 }),
  resolveVmRouteAccountScope: (user: AuthedUser) => {
    scopeCalls.push(user.id);
    return accountScopeRefusal ? { ok: false, response: accountScopeRefusal } : { ok: true };
  },
}));

const listProgram = { program: "list-access-grants" };
const realWorkflows = { ...await import("../services/vms/workflows") };
mock.module("../services/vms/workflows", () => ({
  ...realWorkflows,
  listVmAccessGrants: (input: { userId: string }) => {
    listCalls.push(input);
    return listProgram;
  },
}));

mock.module("../services/vms/routeWorkflow", () => ({
  runVmRoute: async (program: unknown) => {
    expect(program).toBe(listProgram);
    return workflowRefusal ? { ok: false, response: workflowRefusal } : { ok: true, value: devices };
  },
}));

const { GET } = await import("../app/api/vm/access-grants/route");

const request = () => new Request("https://cmux.test/api/vm/access-grants", { headers: { cookie: "stack=1" } });

describe("GET /api/vm/access-grants", () => {
  beforeEach(() => {
    currentUser = { id: "user-1" };
    accountScopeRefusal = null;
    workflowRefusal = null;
    listCalls.length = 0;
    scopeCalls.length = 0;
  });

  test("lists the signed-in user's Mac access grants", async () => {
    const response = await GET(request());
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("private, no-store");
    expect(await response.json()).toEqual({ devices });
    expect(scopeCalls).toEqual(["user-1"]);
    expect(listCalls).toEqual([{ userId: "user-1" }]);
  });

  test("refuses a signed-out request before reading grants", async () => {
    currentUser = null;
    const response = await GET(request());
    expect(response.status).toBe(401);
    expect(listCalls).toEqual([]);
  });

  test("returns the account-scope refusal unchanged", async () => {
    accountScopeRefusal = Response.json({ error: "vm_billing_team_not_found" }, { status: 404 });
    const response = await GET(request());
    expect(response.status).toBe(404);
    expect(listCalls).toEqual([]);
  });

  test("returns the workflow's mapped error response", async () => {
    workflowRefusal = Response.json({ error: "vm_database_unavailable" }, { status: 503 });
    const response = await GET(request());
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "vm_database_unavailable" });
  });
});
