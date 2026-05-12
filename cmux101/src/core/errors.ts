/** Shared error types beyond ProviderError (which lives in types.ts). */

export class ToolError extends Error {
  constructor(message: string, readonly toolName: string, readonly cause?: unknown) {
    super(message);
    this.name = "ToolError";
  }
}

export class PermissionDeniedError extends Error {
  constructor(message: string, readonly toolName: string) {
    super(message);
    this.name = "PermissionDeniedError";
  }
}

export class AbortedError extends Error {
  constructor(message = "Operation aborted") {
    super(message);
    this.name = "AbortedError";
  }
}

export class ConfigError extends Error {
  constructor(message: string, readonly cause?: unknown) {
    super(message);
    this.name = "ConfigError";
  }
}
