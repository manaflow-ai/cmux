const DEVELOPMENT_STACK_PROJECT = "454ecd03-1db2-4050-845e-4ce5b0cd9895";
const BACKEND_HOST = "cmux-dev-backend-1.tail137216.ts.net";

/** Validate both control planes before the E2E runner creates any resource. */
export function vmScopeVerificationEnvironment(env: Record<string, string | undefined>) {
  if (env.CMUX_SCOPE_E2E_ENVIRONMENT !== "isolated-development" ||
      env.NEXT_PUBLIC_STACK_PROJECT_ID !== DEVELOPMENT_STACK_PROJECT) {
    throw new Error("VM scope verification requires the isolated development Stack project");
  }
  const url = new URL(env.CMUX_SCOPE_E2E_ORIGIN ?? "");
  const port = Number(url.port);
  if (url.protocol !== "https:" || url.hostname !== BACKEND_HOST ||
      url.username || url.password || url.pathname !== "/" || url.search || url.hash ||
      !Number.isInteger(port) || port < 3800 || port > 4799) {
    throw new Error("VM scope verification requires a tagged shared-development API origin");
  }
  const sqlHost = env.CMUX_SCOPE_E2E_SQL_HOST;
  const sqlContainer = env.CMUX_SCOPE_E2E_SQL_CONTAINER;
  if (sqlHost !== "ubuntu@cmux-dev-backend-1" || sqlContainer !== `cmux-dev-${port}-postgres-1`) {
    throw new Error("VM scope verification database must match the isolated API instance");
  }
  return { origin: url.origin, sqlHost, sqlContainer };
}

/** Every owned resource gets a cleanup attempt, even after an earlier failure. */
export async function cleanupVmScopeVerification(tasks: readonly {
  readonly name: string;
  readonly run: () => unknown | Promise<unknown>;
}[]): Promise<readonly { name: string; error: unknown }[]> {
  const failures: { name: string; error: unknown }[] = [];
  for (const task of tasks) {
    try { await task.run(); } catch (error) { failures.push({ name: task.name, error }); }
  }
  return failures;
}
