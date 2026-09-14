import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

// Load the real route with isolated dependency mocks. Each child has its own
// module registry, so these mocks cannot alter other CodeRouter test files.
function request(options: Record<string, unknown> = {}) {
  const script = `
    import { mock } from "bun:test";
    const options = ${JSON.stringify(options)};
    const calls = [];
    let resolverArguments = 0;
    mock.module("./services/coderouter/requestContext", () => ({
      resolveCodeRouterRequestContext: async (...args) => {
        resolverArguments = args.length;
        return options.unauthorized ? { ok: false, response: Response.json({ error: "unauthorized" }, { status: 401 }) } : {
          ok: true, value: { user: { id: "user" }, team: { teamId: "source", manageAccounts: options.sourceAllowed !== false } }
        };
      }
    }));
    mock.module("./services/subrouter/routeHelpers", () => ({ authorizedSubrouterTeams: async () => [{ teamId: "destination", manageAccounts: options.destinationAllowed !== false }] }));
    mock.module("./services/coderouter/accounts", () => ({ transferAccount: async (input) => {
      calls.push(input);
      if (options.failTransfer) throw new Error("storage unavailable");
      return true;
    } }));
    const { POST } = await import("./app/api/coderouter/accounts/[accountId]/transfer/route");
    const response = await POST(new Request("https://cmux.test/api/transfer", { method: "POST", body: JSON.stringify({ destinationTeamId: "destination" }) }), { params: Promise.resolve({ accountId: "00000000-0000-4000-8000-000000000001" }) });
    console.log(JSON.stringify({ status: response.status, body: await response.json(), calls, resolverArguments, retryAfter: response.headers.get("retry-after") }));
  `;
  return JSON.parse(execFileSync(process.execPath, ["--eval", script], {
    cwd: fileURLToPath(new URL("..", import.meta.url)), encoding: "utf8",
  }));
}

test("requires management access on the source team before moving credentials", () => {
  const result = request({ sourceAllowed: false });
  expect(result.status).toBe(403);
  expect(result.calls).toHaveLength(0);
});

test("requires management access on the destination and an authenticated caller", () => {
  expect(request({ destinationAllowed: false }).status).toBe(403);
  expect(request({ unauthorized: true }).status).toBe(401);
});

test("uses the current resolver API and passes both authorized teams to storage", () => {
  const result = request();
  expect(result.status).toBe(200);
  expect(result.resolverArguments).toBe(1);
  expect(result.calls).toEqual([{ accountId: "00000000-0000-4000-8000-000000000001", sourceTeamId: "source", destinationTeamId: "destination", stackUserId: "user" }]);
});

test("a failed transfer remains retryable", () => {
  const result = request({ failTransfer: true });
  expect(result.status).toBe(503);
  expect(result.retryAfter).toBe("5");
});
