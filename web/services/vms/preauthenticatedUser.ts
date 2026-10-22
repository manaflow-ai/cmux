import { AsyncLocalStorage } from "node:async_hooks";
import type { AuthedUser } from "./auth";

// A caller that server code has already authenticated by other means (an MCP
// OAuth token, verified by `/api/mcp`) can run `/api/vm` route handlers in
// process. The handlers then skip their own Stack verification and use this
// user, so every ownership, billing and plan rule stays in one code path.
// Only server code can enter this context; no request header or cookie can.

const storage = new AsyncLocalStorage<AuthedUser>();

export function runAsPreauthenticatedVmUser<T>(user: AuthedUser, operation: () => Promise<T>): Promise<T> {
  return storage.run(user, operation);
}

export function preauthenticatedVmUser(): AuthedUser | null {
  return storage.getStore() ?? null;
}
