export class CoderouterConfigurationError extends Error {
  readonly _tag = "CoderouterConfigurationError";
  constructor(readonly operation: string, message: string) {
    super(message);
  }
}

export class CoderouterDatabaseError extends Error {
  readonly _tag = "CoderouterDatabaseError";
  constructor(readonly operation: string, readonly cause: unknown) {
    super(`coderouter database operation failed: ${operation}`);
  }
}

export class CoderouterWorkerSyncError extends Error {
  readonly _tag = "CoderouterWorkerSyncError";
  constructor(readonly operation: string, readonly status: number | null, readonly cause?: unknown) {
    super(`coderouter worker sync failed: ${operation}`);
  }
}

export class CoderouterBillingError extends Error {
  readonly _tag = "CoderouterBillingError";
  constructor(readonly operation: string, readonly cause: unknown) {
    super(`coderouter billing operation failed: ${operation}`);
  }
}

export class CoderouterConnectError extends Error {
  readonly _tag = "CoderouterConnectError";
  constructor(readonly code: "connect_unsupported" | "provider_rejected" | "invalid_state", message: string) {
    super(message);
  }
}

export class CoderouterNotFoundError extends Error {
  readonly _tag = "CoderouterNotFoundError";
  constructor(readonly resource: string) {
    super(`coderouter resource not found: ${resource}`);
  }
}

export type CoderouterWorkflowError =
  | CoderouterConfigurationError
  | CoderouterDatabaseError
  | CoderouterWorkerSyncError
  | CoderouterBillingError
  | CoderouterConnectError
  | CoderouterNotFoundError;

export function coderouterWorkflowErrorCause(err: unknown): CoderouterWorkflowError | null {
  if (
    err instanceof CoderouterConfigurationError ||
    err instanceof CoderouterDatabaseError ||
    err instanceof CoderouterWorkerSyncError ||
    err instanceof CoderouterBillingError ||
    err instanceof CoderouterConnectError ||
    err instanceof CoderouterNotFoundError
  ) {
    return err;
  }
  if (err && typeof err === "object" && "cause" in err) {
    return coderouterWorkflowErrorCause((err as { cause?: unknown }).cause);
  }
  return null;
}
