import { expect, test } from "bun:test";
import { cleanupVmScopeVerification, vmScopeVerificationEnvironment } from "../scripts/coderouter/vmScopeVerification";
const valid = {
  CMUX_SCOPE_E2E_ENVIRONMENT: "isolated-development",
  NEXT_PUBLIC_STACK_PROJECT_ID: "454ecd03-1db2-4050-845e-4ce5b0cd9895",
  CMUX_SCOPE_E2E_ORIGIN: "https://cmux-dev-backend-1.tail137216.ts.net:4438",
  CMUX_SCOPE_E2E_SQL_HOST: "ubuntu@cmux-dev-backend-1",
  CMUX_SCOPE_E2E_SQL_CONTAINER: "cmux-dev-4438-postgres-1",
};
test("verification binds the API, SQL instance, and development Stack project", () => {
  expect(vmScopeVerificationEnvironment(valid).origin).toBe(valid.CMUX_SCOPE_E2E_ORIGIN);
  for (const override of [
    { CMUX_SCOPE_E2E_ENVIRONMENT: "production" }, { NEXT_PUBLIC_STACK_PROJECT_ID: "another-project" },
    { CMUX_SCOPE_E2E_ORIGIN: "https://cmux.com" }, { CMUX_SCOPE_E2E_ORIGIN: "https://coderouter.dev" },
    { CMUX_SCOPE_E2E_ORIGIN: "https://cmux-dev-backend-1.tail137216.ts.net:4438/other" },
    { CMUX_SCOPE_E2E_SQL_CONTAINER: "cmux-dev-4444-postgres-1" }, { CMUX_SCOPE_E2E_SQL_HOST: "ubuntu@another-host" },
  ]) expect(() => vmScopeVerificationEnvironment({ ...valid, ...override })).toThrow();
});
test("cleanup continues after SQL and identity failures", async () => {
  const calls: string[] = [];
  const result = await cleanupVmScopeVerification(['VM', 'SQL', 'team A', 'team B', 'user'].map(name => ({ name, run: async () => {
    calls.push(name); if (name === 'SQL' || name === 'team A') throw new Error('offline');
  } })));
  expect(calls).toEqual(['VM', 'SQL', 'team A', 'team B', 'user']);
  expect(result.map(f => f.name)).toEqual(['SQL', 'team A']);
});
